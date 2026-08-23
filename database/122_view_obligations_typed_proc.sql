-- =====================================================================
-- 122 -- View Obligations (typed projection) sub-proc
--
-- Practice Management is a READ-ONLY consumer of the obligation master
-- that lives in GRAC_New (owned by the Control Management module).
-- After the 7-type obligation taxonomy landed in Control Management
-- scripts 026 / 027 / 028 / 029, the View Obligations screen in PM must
-- surface each obligation's type + typed detail (State rule, Execution
-- spec, Constraint prohibition, Event Response SLA, etc.) plus the M:M
-- evidence attachments from the six per-type link tables.
--
-- This migration adds a NEW standalone stored procedure that projects
-- the typed shape.  It does NOT modify the giant pm_get_practice_repository
-- dispatcher (1580 lines) -- adding a discriminator branch there would
-- require CREATE OR ALTER the entire proc, high blast radius for a
-- read-path extension.  Phase 2E (API) will call this proc directly
-- via a new entity type 'evidence-obligations-typed' routed through
-- PracticeRepositoryService.
--
-- Contract:
--   @p_organization_requirement_id  -- one of these three drives context
--   @p_practice_id                  --   (same shape as the legacy
--   @p_practice_instance_id         --    'evidence-obligations' branch)
--   @p_search       optional case-insensitive substring on ObligationName
--                   or EvidenceType
--   @p_offset       pagination offset (default 0)
--   @p_page_size    pagination row limit (default 200, capped at 500)
--
-- Result set columns (one row per obligation reachable from the context):
--   FrameworkReleaseId, FrameworkRelease,
--   ObligationId, ObligationName,
--   ObligationTypeId, TypeCode, TypeName,
--   ExecutionFrequency, ObligationRetention,
--   ApprovalAuthority, Responsibility,
--   -- Per-type detail as JSON arrays; empty array '[]' when the
--   -- obligation is not of that type or has no active detail rows:
--   StateRulesJson, ExecutionSpecsJson, AssuranceSpecsJson,
--   EventResponsesJson, ConstraintRulesJson, RetentionSpecsJson,
--   -- Combined evidence (legacy 1:M via requirement_obligation_evidence.obligation_id
--   -- PLUS M:M links from all six obligation_<type>_evidence_link tables):
--   EvidenceJson
--
-- The JSON columns are FOR JSON PATH sub-queries returning either an
-- array of objects or NULL (default to '[]' at the SELECT layer).
--
-- Front-end (Phase 2F UI) reads this shape and groups the display by
-- TypeCode; per-type detail cards use the *Json column matching the row's
-- type; EvidenceJson is rendered as a flat table under each obligation.
--
-- Rollback: database/122_view_obligations_typed_proc_rollback.sql
--
-- Safe to re-run (CREATE OR ALTER).  ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
GO

-- Preflight: Control Management scripts 026 must be applied first so the
-- new type-master + detail tables + link tables exist in GRAC_New.
IF OBJECT_ID('GRAC_New.obligation_type_master','U') IS NULL
BEGIN
    RAISERROR('122 preflight failed: Control Management scripts 026 (schema) + 027 (data) must be applied first.', 16, 1);
    RETURN;
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
        o.obligation_type_id AS ObligationTypeId,
        t.type_code AS TypeCode,
        t.type_name AS TypeName,
        COALESCE(exec_freq.option_label, o.frequency_type) AS ExecutionFrequency,
        o.retention_requirement AS ObligationRetention,
        o.approval_authority AS ApprovalAuthority,
        o.responsibility AS Responsibility,
        -- Per-type detail JSON.  Each returns [] when no active rows.
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
        -- Combined evidence.  Legacy 1:M rows in requirement_obligation_evidence
        -- carry obligation_id (still populated for standalone Evidence obligations
        -- and pre-taxonomy rows).  M:M links come from the six per-type
        -- obligation_<type>_evidence_link tables installed by CM 026.
        COALESCE((
            SELECT * FROM (
                -- Legacy 1:M (Evidence-type obligations + pre-taxonomy)
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
                -- M:M links via per-type link tables
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

PRINT '122 sp_pm_view_obligations_typed installed.';
GO
