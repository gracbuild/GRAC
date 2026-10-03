-- =====================================================================
-- 396 Repository copy model -- "Retired in repository" flag on screens
--
-- Design section 4.6 (sir's decision 4, 2026-09-28): an approved
-- repository retirement only FLAGS the organization's copy
-- (lifecycle_status = 'Retired'); practices, instances and tasks stay, and
-- the screens show a "Retired in repository" badge. 395 sets the flag;
-- this file exposes it where the badge is drawn:
--   sp_resolve_obligation_list (394) + RepositoryLifecycleStatus
--       (NULL on organization-defined obligations)
--   sp_practice_detail_get (393)     + RepositoryLifecycleStatus in each
--       MappedSourceStatementsJson entry
-- The statement tree and the Standards & Frameworks counts get the flag in
-- PracticeRepositoryService.cs (same change): the tree shows the badge,
-- and a retired statement no longer counts towards the release totals.
--
-- Found by 395's first detection run: CH4 (framework_statement_id 28,
-- release 6) was already Inactive in grac_new before the 391 copy; it is
-- a pending Retired change for organizations 1, 2 and 4.
--
-- Re-issued from the files named; nothing else in them changes.
-- SAFE TO RE-RUN. Requires 394 and 395.
-- Rollback: 396_repository_retired_flag_on_screens_rollback.sql
-- ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID('grac_practice.organization_repository_change','U') IS NULL
   OR COL_LENGTH('grac_practice.organization_obligation','lifecycle_status') IS NULL
   OR COL_LENGTH('grac_practice.organization_framework_statements','lifecycle_status') IS NULL
BEGIN
    PRINT 'ABORT (396): run 391-395 first.';
    SET NOEXEC ON;
END
GO

-- sp_resolve_obligation_list (from 394)
CREATE OR ALTER PROCEDURE grac_practice.sp_resolve_obligation_list
    @practice_instance_id BIGINT,
    @include_unsubscribed BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    IF @practice_instance_id IS NULL
        THROW 52604, 'sp_resolve_obligation_list: practice_instance_id is required.', 1;

    DECLARE @organization_id BIGINT, @practice_id BIGINT;
    SELECT @organization_id = organization_id, @practice_id = practice_id
    FROM   grac_practice.practice_instance
    WHERE  practice_instance_id = @practice_instance_id;

    IF @organization_id IS NULL
        THROW 52605, 'sp_resolve_obligation_list: instance not found.', 1;

    ;WITH reachable AS (
        SELECT orm.obligation_id,
               orm.release_id,
               CAST(CASE WHEN EXISTS (SELECT 1 FROM grac_practice.repository_subscription s
                                       WHERE s.organization_id = @organization_id
                                         AND s.release_id = orm.release_id
                                         AND s.status = N'Active')
                         THEN 1 ELSE 0 END AS BIT) AS is_subscribed
        FROM   grac_practice.practice pp
        JOIN   grac_practice.organization_requirement req
               ON req.organization_requirement_id = pp.organization_requirement_id
        LEFT   JOIN grac_practice.fn_org_requirement(@organization_id) repo_req
               ON repo_req.requirement_code = req.requirement_code AND repo_req.status = N'Active'
        JOIN   grac_practice.fn_org_obligation_requirement_release_map(@organization_id) orm
               ON orm.requirement_id = COALESCE(req.repository_requirement_id, repo_req.requirement_id)
              AND orm.status = N'Active'
        WHERE  pp.practice_id = @practice_id
    ),
    picked AS (
        SELECT obligation_id,
               MIN(release_id)                 AS release_id,
               MAX(CAST(is_subscribed AS INT)) AS is_subscribed
        FROM   reachable
        WHERE  @include_unsubscribed = 1 OR is_subscribed = 1
        GROUP  BY obligation_id
    )
    SELECT * FROM (
    SELECT
        o.obligation_id                 AS ObligationId,
        CAST(0 AS BIT)                  AS IsOrganizationDefined,
        N'p' + CAST(o.obligation_id AS NVARCHAR(20)) AS RowKey,
        ISNULL(t.display_order, 999)    AS SortOrder,
        COALESCE(NULLIF(LTRIM(RTRIM(o.obligation_name)), N''),
                 LEFT(o.obligation_text, 300))          AS ObligationName,
        o.obligation_text               AS ObligationText,
        o.obligation_text               AS ObligationDescription,
        t.type_code                     AS TypeCode,
        t.type_name                     AS TypeName,
        pk.release_id                   AS ReleaseId,
        COALESCE(a.artifact_code + N' ' + r.version_no,
                 a.artifact_name + N' ' + r.version_no,
                 r.version_no)          AS FrameworkRelease,
        CAST(pk.is_subscribed AS BIT)   AS IsSubscribed,

        COALESCE(exec_freq.option_label, o.frequency_type) AS PublishedExecutionFrequency,
        o.responsibility                AS PublishedResponsibility,
        o.approval_authority            AS PublishedApprovalAuthority,
        o.retention_requirement         AS PublishedRetention,

        COALESCE(td.StateRulesJson,      N'[]') AS StateRulesJson,
        COALESCE(td.ExecutionSpecsJson,  N'[]') AS ExecutionSpecsJson,
        COALESCE(td.AssuranceSpecsJson,  N'[]') AS AssuranceSpecsJson,
        COALESCE(td.EventResponsesJson,  N'[]') AS EventResponsesJson,
        COALESCE(td.ConstraintRulesJson, N'[]') AS ConstraintRulesJson,
        COALESCE(td.RetentionSpecsJson,  N'[]') AS RetentionSpecsJson,
        COALESCE(td.EvidenceJson,        N'[]') AS PublishedEvidenceJson,

        adopt.practice_instance_obligation_id AS AdoptionId,
        CAST(CASE WHEN adopt.practice_instance_obligation_id IS NULL THEN 0 ELSE 1 END AS BIT) AS IsAdopted,
        adopt.organization_modified     AS OrganizationModified,
        adopt.execution_frequency_id    AS ExecutionFrequencyId,
        adopt.execution_frequency       AS ExecutionFrequency,
        adopt.assurance_frequency_id    AS AssuranceFrequencyId,
        adopt.assurance_frequency       AS AssuranceFrequency,
        adopt.event_type_id             AS EventTypeId,
        adopt.sla_value                 AS SlaValue,
        adopt.sla_unit                  AS SlaUnit,
        adopt.implementation_status_id  AS ImplementationStatusId,
        -- Migration 244: connection payload for Automated assurance.
        -- Null on any obligation that has not been configured yet.
        adopt.connection_type_id        AS ConnectionTypeId,
        adopt.connection_url            AS ConnectionUrl,
        adopt.responsibility            AS Responsibility,
        adopt.approval_authority        AS ApprovalAuthority,
        adopt.retention_period          AS RetentionPeriod,
        adopt.assurance_type            AS AdoptedAssuranceType,
        adopt.remarks                   AS Remarks,
        adopt.adopted_by                AS AdoptedBy,
        adopt.adopted_dt                AS AdoptedDt,

        ev.PublishedEvidenceCount       AS PublishedEvidenceCount,
        ev.ResolvedEvidenceCount        AS ResolvedEvidenceCount,
        -- 396: 'Retired' once a repository retirement of this obligation
        -- has been approved (flag only -- the card stays, with a badge).
        o.lifecycle_status              AS RepositoryLifecycleStatus
    FROM   picked pk
    JOIN   grac_practice.fn_org_requirement_obligation(@organization_id) o
           ON o.obligation_id = pk.obligation_id AND o.status = N'Active'
    LEFT   JOIN GRAC_New.obligation_type_master t
           ON t.obligation_type_id = o.obligation_type_id
    LEFT   JOIN GRAC_New.reference_option exec_freq
           ON exec_freq.reference_option_id = o.execution_frequency_id
    LEFT   JOIN GRAC_New.release r ON r.release_id = pk.release_id
    LEFT   JOIN GRAC_New.artifact a ON a.artifact_id = r.artifact_id
    LEFT   JOIN grac_practice.vw_pm_org_obligation_typed_detail td
           ON td.OrganizationId = @organization_id
          AND td.ObligationId = pk.obligation_id
    LEFT   JOIN grac_practice.practice_instance_obligation adopt
           ON adopt.practice_instance_id = @practice_instance_id
          AND adopt.obligation_id        = pk.obligation_id
          AND adopt.status               = N'Active'
    OUTER  APPLY (
        SELECT COUNT(DISTINCT oe.evidence_type_id) AS PublishedEvidenceCount,
               (SELECT COUNT(*) FROM grac_practice.practice_instance_evidence pie
                 WHERE pie.practice_instance_id = @practice_instance_id
                   AND pie.source_obligation_id = pk.obligation_id
                   AND pie.status = N'Active'
                   -- 353: an evidence row counts as RESOLVED only once its
                   -- location AND locator are both filled (same test as
                   -- sp_resolve_evidence_list.IsResolved). Before this it
                   -- counted every row that merely EXISTS, so an empty
                   -- evidence row created by the single obligation+evidence
                   -- save turned the obligation green with no details entered.
                   AND NULLIF(LTRIM(RTRIM(ISNULL(pie.evidence_location, N''))), N'') IS NOT NULL
                   AND NULLIF(LTRIM(RTRIM(ISNULL(pie.evidence_locator,  N''))), N'') IS NOT NULL) AS ResolvedEvidenceCount
        FROM   grac_practice.vw_pm_obligation_evidence oe
        WHERE  oe.organization_id = @organization_id
          AND  oe.obligation_id = pk.obligation_id
    ) ev

    UNION ALL
    SELECT
        CAST(NULL AS BIGINT)            AS ObligationId,
        CAST(1 AS BIT)                  AS IsOrganizationDefined,
        N'l' + CAST(pio.practice_instance_obligation_id AS NVARCHAR(20)) AS RowKey,
        1000 + CAST(pio.practice_instance_obligation_id % 1000 AS INT) AS SortOrder,
        pio.obligation_name             AS ObligationName,
        pio.obligation_description      AS ObligationText,
        pio.obligation_description      AS ObligationDescription,
        pio.obligation_type_code        AS TypeCode,
        lt.type_name                    AS TypeName,
        CAST(NULL AS BIGINT)            AS ReleaseId,
        CAST(NULL AS NVARCHAR(400))     AS FrameworkRelease,
        CAST(1 AS BIT)                  AS IsSubscribed,

        CAST(NULL AS NVARCHAR(200))     AS PublishedExecutionFrequency,
        CAST(NULL AS NVARCHAR(300))     AS PublishedResponsibility,
        CAST(NULL AS NVARCHAR(300))     AS PublishedApprovalAuthority,
        CAST(NULL AS NVARCHAR(200))     AS PublishedRetention,

        CASE WHEN pio.obligation_type_code = N'State'         THEN ISNULL(pio.typed_detail_json, N'[]') ELSE N'[]' END AS StateRulesJson,
        CASE WHEN pio.obligation_type_code = N'Execution'     THEN ISNULL(pio.typed_detail_json, N'[]') ELSE N'[]' END AS ExecutionSpecsJson,
        CASE WHEN pio.obligation_type_code = N'Assurance'     THEN ISNULL(pio.typed_detail_json, N'[]') ELSE N'[]' END AS AssuranceSpecsJson,
        CASE WHEN pio.obligation_type_code = N'EventResponse' THEN ISNULL(pio.typed_detail_json, N'[]') ELSE N'[]' END AS EventResponsesJson,
        CASE WHEN pio.obligation_type_code = N'Constraint'    THEN ISNULL(pio.typed_detail_json, N'[]') ELSE N'[]' END AS ConstraintRulesJson,
        CASE WHEN pio.obligation_type_code = N'Retention'     THEN ISNULL(pio.typed_detail_json, N'[]') ELSE N'[]' END AS RetentionSpecsJson,
        CASE WHEN pio.obligation_type_code = N'Evidence'      THEN ISNULL(pio.typed_detail_json, N'[]') ELSE N'[]' END AS PublishedEvidenceJson,

        pio.practice_instance_obligation_id AS AdoptionId,
        CAST(1 AS BIT)                  AS IsAdopted,
        CAST(1 AS BIT)                  AS OrganizationModified,
        pio.execution_frequency_id      AS ExecutionFrequencyId,
        pio.execution_frequency         AS ExecutionFrequency,
        pio.assurance_frequency_id      AS AssuranceFrequencyId,
        pio.assurance_frequency         AS AssuranceFrequency,
        pio.event_type_id               AS EventTypeId,
        pio.sla_value                   AS SlaValue,
        pio.sla_unit                    AS SlaUnit,
        pio.implementation_status_id    AS ImplementationStatusId,
        -- Migration 244: mirrors the top half.
        pio.connection_type_id          AS ConnectionTypeId,
        pio.connection_url              AS ConnectionUrl,
        pio.responsibility              AS Responsibility,
        pio.approval_authority          AS ApprovalAuthority,
        pio.retention_period            AS RetentionPeriod,
        pio.assurance_type              AS AdoptedAssuranceType,
        pio.remarks                     AS Remarks,
        pio.adopted_by                  AS AdoptedBy,
        pio.adopted_dt                  AS AdoptedDt,

        0                               AS PublishedEvidenceCount,
        (SELECT COUNT(*) FROM grac_practice.practice_instance_evidence pie2
          WHERE pie2.practice_instance_id = @practice_instance_id
            AND pie2.source_practice_instance_obligation_id = pio.practice_instance_obligation_id
            AND pie2.status = N'Active'
            -- 353: resolved = location AND locator both filled (see fix above).
            AND NULLIF(LTRIM(RTRIM(ISNULL(pie2.evidence_location, N''))), N'') IS NOT NULL
            AND NULLIF(LTRIM(RTRIM(ISNULL(pie2.evidence_locator,  N''))), N'') IS NOT NULL)  AS ResolvedEvidenceCount,
        CAST(NULL AS NVARCHAR(20))      AS RepositoryLifecycleStatus
    FROM   grac_practice.practice_instance_obligation pio
    LEFT   JOIN GRAC_New.obligation_type_master lt
           ON lt.type_code = pio.obligation_type_code
    WHERE  pio.practice_instance_id = @practice_instance_id
      AND  pio.obligation_id IS NULL
      AND  pio.status = N'Active'
    ) x
    ORDER  BY x.SortOrder, x.ObligationName;
END
GO

-- sp_practice_detail_get (from 393)
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

-- Verification: expect 2 rows, HasFlag = 1 on both.
SELECT N'sp_resolve_obligation_list' AS ObjectName,
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_resolve_obligation_list')) LIKE '%RepositoryLifecycleStatus%' THEN 1 ELSE 0 END AS HasFlag
UNION ALL
SELECT N'sp_practice_detail_get',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_practice_detail_get')) LIKE '%RepositoryLifecycleStatus%' THEN 1 ELSE 0 END;
GO
PRINT '396 complete.';
GO
