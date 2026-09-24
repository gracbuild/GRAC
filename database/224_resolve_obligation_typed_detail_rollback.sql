-- =====================================================================
-- 224 Typed obligation detail -- ROLLBACK
--
-- Undoes database/224_resolve_obligation_typed_detail.sql:
--   1. Restores grac_practice.sp_resolve_obligation_list to the exact
--      141_resolve_workspace_procs.sql body (no typed columns, no view).
--   2. Restores dbo.sp_pm_view_obligations_typed to the exact
--      122_view_obligations_typed_proc.sql body -- the seven sub-queries
--      back inline, so it no longer depends on the view.
--   3. Drops grac_practice.vw_pm_obligation_typed_detail.
--
-- ORDER MATTERS: the view is dropped LAST, because steps 1 and 2 are
-- what remove the only references to it.
--
-- REVERT THE APP FIRST. The Api reads the typed columns defensively
-- (HasColumn), so an Api build that knows about 224 keeps working
-- against a rolled-back database -- the workspace card simply falls back
-- to the published four fields. The reverse is also safe. No ordering
-- constraint between the tiers, only this one inside the script.
--
-- NO DATA IS UNDONE: 224 writes nothing. The obligation detail rows live
-- in GRAC_New and belong to Control Management.
--
-- ASCII-only on purpose (see the forward script header).
-- Idempotent: safe to re-run.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF SCHEMA_ID('grac_practice') IS NULL OR SCHEMA_ID('GRAC_New') IS NULL
BEGIN
    PRINT 'ABORT (224 rollback): schema grac_practice or GRAC_New missing.';
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. sp_resolve_obligation_list -- back to the 141 body.
-- =====================================================================
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
        LEFT   JOIN GRAC_New.requirement repo_req
               ON repo_req.requirement_code = req.requirement_code AND repo_req.status = N'Active'
        JOIN   GRAC_New.obligation_requirement_release_map orm
               ON orm.requirement_id = COALESCE(req.repository_requirement_id, repo_req.requirement_id)
              AND orm.status = N'Active'
        WHERE  pp.practice_id = @practice_id
    ),
    picked AS (
        SELECT obligation_id,
               MIN(release_id)      AS release_id,
               MAX(CAST(is_subscribed AS INT)) AS is_subscribed
        FROM   reachable
        WHERE  @include_unsubscribed = 1 OR is_subscribed = 1
        GROUP  BY obligation_id
    )
    SELECT
        o.obligation_id                 AS ObligationId,
        COALESCE(NULLIF(LTRIM(RTRIM(o.obligation_name)), N''),
                 LEFT(o.obligation_text, 300))          AS ObligationName,
        o.obligation_text               AS ObligationText,
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

        adopt.practice_instance_obligation_id AS AdoptionId,
        CAST(CASE WHEN adopt.practice_instance_obligation_id IS NULL THEN 0 ELSE 1 END AS BIT) AS IsAdopted,
        adopt.organization_modified     AS OrganizationModified,
        adopt.execution_frequency_id    AS ExecutionFrequencyId,
        adopt.execution_frequency       AS ExecutionFrequency,
        adopt.assurance_frequency_id    AS AssuranceFrequencyId,
        adopt.assurance_frequency       AS AssuranceFrequency,
        adopt.responsibility            AS Responsibility,
        adopt.approval_authority        AS ApprovalAuthority,
        adopt.retention_period          AS RetentionPeriod,
        adopt.remarks                   AS Remarks,
        adopt.adopted_by                AS AdoptedBy,
        adopt.adopted_dt                AS AdoptedDt,

        ev.PublishedEvidenceCount       AS PublishedEvidenceCount,
        ev.ResolvedEvidenceCount        AS ResolvedEvidenceCount
    FROM   picked pk
    JOIN   GRAC_New.requirement_obligation o
           ON o.obligation_id = pk.obligation_id AND o.status = N'Active'
    LEFT   JOIN GRAC_New.obligation_type_master t
           ON t.obligation_type_id = o.obligation_type_id
    LEFT   JOIN GRAC_New.reference_option exec_freq
           ON exec_freq.reference_option_id = o.execution_frequency_id
    LEFT   JOIN GRAC_New.release r ON r.release_id = pk.release_id
    LEFT   JOIN GRAC_New.artifact a ON a.artifact_id = r.artifact_id
    LEFT   JOIN grac_practice.practice_instance_obligation adopt
           ON adopt.practice_instance_id = @practice_instance_id
          AND adopt.obligation_id        = pk.obligation_id
          AND adopt.status               = N'Active'
    OUTER  APPLY (
        SELECT COUNT(DISTINCT roe.evidence_type_id) AS PublishedEvidenceCount,
               (SELECT COUNT(*) FROM grac_practice.practice_instance_evidence pie
                 WHERE pie.practice_instance_id = @practice_instance_id
                   AND pie.source_obligation_id = pk.obligation_id
                   AND pie.status = N'Active') AS ResolvedEvidenceCount
        FROM   GRAC_New.requirement_obligation_evidence roe
        WHERE  roe.obligation_id = pk.obligation_id
    ) ev
    ORDER  BY ISNULL(t.display_order, 999),
              COALESCE(o.obligation_name, o.obligation_text);
END
GO

PRINT '224 rollback: sp_resolve_obligation_list restored to the 141 body.';
GO

-- =====================================================================
-- 2. sp_pm_view_obligations_typed -- back to the 122 body, sub-queries
--    inline.
-- =====================================================================
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
        o.obligation_type_id AS ObligationTypeId,
        t.type_code AS TypeCode,
        t.type_name AS TypeName,
        COALESCE(exec_freq.option_label, o.frequency_type) AS ExecutionFrequency,
        o.retention_requirement AS ObligationRetention,
        o.approval_authority AS ApprovalAuthority,
        o.responsibility AS Responsibility,
        COALESCE((
            SELECT s.state_rule_id AS Id,
                   s.attribute, s.operator, s.[value], s.unit, s.tolerance, s.remarks
            FROM GRAC_New.obligation_state_rule s
            WHERE s.obligation_id = o.obligation_id AND s.status = N'Active'
            FOR JSON PATH
        ), N'[]') AS StateRulesJson,
        COALESCE((
            SELECT es.execution_spec_id AS Id,
                   es.[action],
                   es.execution_frequency_id AS ExecutionFrequencyId,
                   ef.option_label AS ExecutionFrequency,
                   es.trigger_condition, es.responsible_party, es.due_within, es.remarks
            FROM GRAC_New.obligation_execution_spec es
            LEFT JOIN GRAC_New.reference_option ef ON ef.reference_option_id = es.execution_frequency_id
            WHERE es.obligation_id = o.obligation_id AND es.status = N'Active'
            FOR JSON PATH
        ), N'[]') AS ExecutionSpecsJson,
        COALESCE((
            SELECT [as].assurance_spec_id AS Id,
                   [as].verification_method, [as].scope,
                   [as].assurance_frequency_id AS AssuranceFrequencyId,
                   af.option_label AS AssuranceFrequency,
                   [as].assurance_party, [as].remarks
            FROM GRAC_New.obligation_assurance_spec [as]
            LEFT JOIN GRAC_New.reference_option af ON af.reference_option_id = [as].assurance_frequency_id
            WHERE [as].obligation_id = o.obligation_id AND [as].status = N'Active'
            FOR JSON PATH
        ), N'[]') AS AssuranceSpecsJson,
        COALESCE((
            SELECT er.event_response_id AS Id,
                   er.trigger_event, er.response_action,
                   er.sla_value AS SlaValue, er.sla_unit AS SlaUnit,
                   er.escalation_path, er.remarks
            FROM GRAC_New.obligation_event_response er
            WHERE er.obligation_id = o.obligation_id AND er.status = N'Active'
            FOR JSON PATH
        ), N'[]') AS EventResponsesJson,
        COALESCE((
            SELECT cr.constraint_rule_id AS Id,
                   cr.prohibited_condition, cr.scope, cr.exception_policy, cr.remarks
            FROM GRAC_New.obligation_constraint_rule cr
            WHERE cr.obligation_id = o.obligation_id AND cr.status = N'Active'
            FOR JSON PATH
        ), N'[]') AS ConstraintRulesJson,
        COALESCE((
            SELECT rs.retention_spec_id AS Id,
                   rs.retained_object,
                   rs.min_retention_value AS MinRetentionValue, rs.min_retention_unit AS MinRetentionUnit,
                   rs.max_retention_value AS MaxRetentionValue, rs.max_retention_unit AS MaxRetentionUnit,
                   rs.disposal_policy, rs.remarks
            FROM GRAC_New.obligation_retention_spec rs
            WHERE rs.obligation_id = o.obligation_id AND rs.status = N'Active'
            FOR JSON PATH
        ), N'[]') AS RetentionSpecsJson,
        COALESCE((
            SELECT * FROM (
                SELECT
                    N'Direct' AS Source,
                    NULL AS LinkTypeCode,
                    roe.obligation_evidence_id AS ObligationEvidenceId,
                    roe.evidence_type_id AS EvidenceTypeId,
                    et.evidence_type_name AS EvidenceType,
                    roe.frequency_id AS FrequencyId,
                    freq.option_label AS Frequency,
                    roe.retention_requirement AS RetentionRequirement,
                    roe.remarks AS Remarks,
                    et.display_order AS DisplayOrder
                FROM GRAC_New.requirement_obligation_evidence roe
                LEFT JOIN GRAC_New.evidence_type_master et ON et.evidence_type_id = roe.evidence_type_id
                LEFT JOIN GRAC_New.reference_option freq ON freq.reference_option_id = roe.frequency_id
                WHERE roe.obligation_id = o.obligation_id
                  AND roe.status = N'Active'
                UNION ALL
                SELECT N'Link', l.TypeCode,
                       roe2.obligation_evidence_id, roe2.evidence_type_id,
                       et2.evidence_type_name,
                       roe2.frequency_id, freq2.option_label,
                       roe2.retention_requirement, roe2.remarks,
                       et2.display_order
                FROM (
                    SELECT N'State' AS TypeCode, obligation_id, obligation_evidence_id, status
                    FROM GRAC_New.obligation_state_evidence_link
                    UNION ALL SELECT N'Execution', obligation_id, obligation_evidence_id, status
                    FROM GRAC_New.obligation_execution_evidence_link
                    UNION ALL SELECT N'Assurance', obligation_id, obligation_evidence_id, status
                    FROM GRAC_New.obligation_assurance_evidence_link
                    UNION ALL SELECT N'EventResponse', obligation_id, obligation_evidence_id, status
                    FROM GRAC_New.obligation_event_response_evidence_link
                    UNION ALL SELECT N'Constraint', obligation_id, obligation_evidence_id, status
                    FROM GRAC_New.obligation_constraint_evidence_link
                    UNION ALL SELECT N'Retention', obligation_id, obligation_evidence_id, status
                    FROM GRAC_New.obligation_retention_evidence_link
                ) l
                JOIN GRAC_New.requirement_obligation_evidence roe2 ON roe2.obligation_evidence_id = l.obligation_evidence_id
                LEFT JOIN GRAC_New.evidence_type_master et2 ON et2.evidence_type_id = roe2.evidence_type_id
                LEFT JOIN GRAC_New.reference_option freq2 ON freq2.reference_option_id = roe2.frequency_id
                WHERE l.obligation_id = o.obligation_id
                  AND l.status = N'Active'
            ) combined
            ORDER BY combined.Source, ISNULL(combined.DisplayOrder, 999), combined.EvidenceType
            FOR JSON PATH
        ), N'[]') AS EvidenceJson
    FROM distinct_obligations dob
    JOIN GRAC_New.requirement_obligation o
        ON o.obligation_id = dob.obligation_id AND o.status = N'Active'
    LEFT JOIN GRAC_New.obligation_type_master t
        ON t.obligation_type_id = o.obligation_type_id
    LEFT JOIN GRAC_New.reference_option exec_freq
        ON exec_freq.reference_option_id = o.execution_frequency_id
    OUTER APPLY (
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

PRINT '224 rollback: sp_pm_view_obligations_typed restored to the 122 body.';
GO

-- =====================================================================
-- 3. Drop the view -- last, now that nothing references it.
-- =====================================================================
IF OBJECT_ID('grac_practice.vw_pm_obligation_typed_detail','V') IS NOT NULL
BEGIN
    DROP VIEW grac_practice.vw_pm_obligation_typed_detail;
    PRINT '224 rollback: vw_pm_obligation_typed_detail dropped.';
END
GO

-- =====================================================================
-- 4. Verification
-- =====================================================================
PRINT '=== 224 rollback verification ===';

SELECT 'view removed' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.vw_pm_obligation_typed_detail','V') IS NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT 'sp_resolve_obligation_list is the 141 body',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_resolve_obligation_list','P'))
                 LIKE '%vw_pm_obligation_typed_detail%'
            THEN 'FAIL -- still references the view' ELSE 'PASS' END
UNION ALL
SELECT 'sp_pm_view_obligations_typed is the 122 body',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('dbo.sp_pm_view_obligations_typed','P'))
                 LIKE '%obligation_state_rule%'
            THEN 'PASS' ELSE 'FAIL -- sub-queries not restored' END;

PRINT '';
PRINT '224 rollback complete. The obligation card falls back to the four';
PRINT 'published fields; the View Obligations screen is unchanged.';
GO

SET NOEXEC OFF;
GO
