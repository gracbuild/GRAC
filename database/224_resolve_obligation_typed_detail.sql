-- =====================================================================
-- 224 Typed obligation detail on the Operationalize workspace
--
-- WHAT WAS WRONG
-- --------------
-- The obligation card on Resolve / Operationalize showed the same four
-- published facts for every obligation:
--
--     Published frequency | Responsibility | Approval | Retention
--
-- Those are the columns the PRE-TAXONOMY flat model had. Control
-- Management has since moved to the seven-type obligation taxonomy
-- (CM 026 / 027), where each type carries its own fields and the admin
-- module captures them accordingly:
--
--     State          attribute, operator, value, unit, tolerance
--     Execution      action, frequency, trigger condition,
--                    responsible party, due within
--     Assurance      verification method, scope, frequency,
--                    assurance party
--     EventResponse  trigger event, response action, SLA, escalation
--     Constraint     prohibited condition, scope, exception policy
--     Retention      retained object, min/max retention, disposal policy
--     Evidence       (cross-cutting -- attachable to all six)
--
-- A State obligation shown as "frequency / responsibility / approval /
-- retention" reads as four dashes. The rule it actually carries --
-- "password length >= 12" -- was nowhere on the screen.
--
-- WHAT THIS DOES
-- --------------
--   1. grac_practice.vw_pm_obligation_typed_detail
--      One row per obligation: the six per-type detail arrays and the
--      combined evidence array, as JSON.
--
--   2. sp_resolve_obligation_list -- re-issued from the 141 body with
--      the view joined on, so the workspace card can render the fields
--      that obligation actually has.
--
--   3. dbo.sp_pm_view_obligations_typed -- re-issued from the 122 body
--      to select the same columns FROM THE VIEW instead of repeating the
--      sub-queries inline.
--
-- WHY A VIEW AND NOT A SECOND COPY
-- --------------------------------
-- Migration 122 already wrote this projection once, for the View
-- Obligations screen. Pasting it into sp_resolve_obligation_list would
-- make two places that have to learn about an eighth obligation type,
-- and the second one to be forgotten is the bug. The sub-queries are
-- keyed purely on obligation_id -- no context, no parameters -- so they
-- lift into a view unchanged, and both procedures select from it.
--
-- The projection below is 122's, column for column and alias for alias.
-- sp_pm_view_obligations_typed's result set is therefore unchanged; only
-- where the values come from has moved.
--
-- ASCII-only on purpose: sqlcmd reads files in the current ANSI codepage
-- by default and multi-byte characters can corrupt string literals.
--
-- Idempotent: CREATE OR ALTER throughout; no data is written.
--
-- DEPENDS ON: Control Management 026/027 (obligation_type_master, the
--             six detail tables, the six evidence link tables in
--             GRAC_New), 122 (the projection this extracts), 140/141
--             (the Resolve workspace).
-- Rollback:   database/224_resolve_obligation_typed_detail_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;   -- defensive: reset in case a prior script left it on
GO

-- ---------------------------------------------------------------------
-- Prerequisite guard.
--
-- The six detail tables and six link tables live in GRAC_New and belong
-- to Control Management. Practice Management is a read-only consumer, so
-- this script cannot create them -- it can only refuse to run.
-- ---------------------------------------------------------------------
DECLARE @prereqs_ok BIT = 1;

IF SCHEMA_ID('grac_practice') IS NULL OR SCHEMA_ID('GRAC_New') IS NULL
BEGIN
    PRINT 'ABORT (224): schema grac_practice or GRAC_New missing.';
    SET @prereqs_ok = 0;
END

IF OBJECT_ID('GRAC_New.obligation_type_master','U') IS NULL
   OR OBJECT_ID('GRAC_New.obligation_state_rule','U')      IS NULL
   OR OBJECT_ID('GRAC_New.obligation_execution_spec','U')  IS NULL
   OR OBJECT_ID('GRAC_New.obligation_assurance_spec','U')  IS NULL
   OR OBJECT_ID('GRAC_New.obligation_event_response','U')  IS NULL
   OR OBJECT_ID('GRAC_New.obligation_constraint_rule','U') IS NULL
   OR OBJECT_ID('GRAC_New.obligation_retention_spec','U')  IS NULL
BEGIN
    PRINT 'ABORT (224): obligation taxonomy tables missing. Apply Control Management 026 (schema) and 027 (data) first.';
    SET @prereqs_ok = 0;
END

IF OBJECT_ID('GRAC_New.obligation_state_evidence_link','U')          IS NULL
   OR OBJECT_ID('GRAC_New.obligation_execution_evidence_link','U')      IS NULL
   OR OBJECT_ID('GRAC_New.obligation_assurance_evidence_link','U')      IS NULL
   OR OBJECT_ID('GRAC_New.obligation_event_response_evidence_link','U') IS NULL
   OR OBJECT_ID('GRAC_New.obligation_constraint_evidence_link','U')     IS NULL
   OR OBJECT_ID('GRAC_New.obligation_retention_evidence_link','U')      IS NULL
BEGIN
    PRINT 'ABORT (224): obligation evidence link tables missing. Apply Control Management 026 first.';
    SET @prereqs_ok = 0;
END

IF OBJECT_ID('grac_practice.sp_resolve_obligation_list','P') IS NULL
BEGIN
    PRINT 'ABORT (224): sp_resolve_obligation_list missing. Run 141_resolve_workspace_procs.sql first.';
    SET @prereqs_ok = 0;
END

IF @prereqs_ok = 0
BEGIN
    RAISERROR('224_resolve_obligation_typed_detail: prerequisites missing -- see PRINT messages above.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. vw_pm_obligation_typed_detail
--
--    One row per obligation. Every column is an array; an obligation
--    that is not of a given type simply has '[]' there, so a consumer
--    can render whichever column matches its TypeCode without a second
--    query or a CASE.
--
--    No status filter on the base row: consumers apply their own (141
--    wants Active obligations, and a future caller may want all of
--    them). The detail rows ARE filtered to Active, because a retired
--    state rule is not part of the obligation any more.
--
--    Not SCHEMABINDING -- it reads GRAC_New, which Control Management
--    owns and reshapes on its own schedule; binding this view into its
--    tables would make a CM migration fail against a PM object.
-- =====================================================================
CREATE OR ALTER VIEW grac_practice.vw_pm_obligation_typed_detail
AS
    SELECT
        o.obligation_id AS ObligationId,

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

        -- Combined evidence. Legacy 1:M rows in
        -- requirement_obligation_evidence carry obligation_id (still
        -- populated for standalone Evidence obligations and pre-taxonomy
        -- rows). M:M links come from the six per-type link tables.
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

    FROM GRAC_New.requirement_obligation o;
GO

-- =====================================================================
-- 2. sp_resolve_obligation_list -- re-issued
--
--    The 141 body, unchanged, plus:
--      * ObligationDescription  -- the published statement, labelled so
--                                  the card can show it as a description
--                                  rather than an unlabelled paragraph
--      * the seven JSON columns from the view
--
--    Keep this in step with 141 if that file is ever revised.
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
    -- One row per obligation. Where the same obligation rides several
    -- subscribed releases, the lowest release_id is the representative --
    -- an arbitrary but stable choice, so the card does not reshuffle
    -- between loads.
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
        -- Same value as ObligationText. Named separately because the card
        -- shows it under a "Description" heading, and a caller reading
        -- ObligationText for the title fallback should not have to know
        -- that the two uses are the same column today.
        o.obligation_text               AS ObligationDescription,
        t.type_code                     AS TypeCode,
        t.type_name                     AS TypeName,
        pk.release_id                   AS ReleaseId,
        COALESCE(a.artifact_code + N' ' + r.version_no,
                 a.artifact_name + N' ' + r.version_no,
                 r.version_no)          AS FrameworkRelease,
        CAST(pk.is_subscribed AS BIT)   AS IsSubscribed,

        -- As published. Kept for the pre-taxonomy obligations that still
        -- carry only these, and as the fallback when a typed obligation
        -- has no detail rows yet.
        COALESCE(exec_freq.option_label, o.frequency_type) AS PublishedExecutionFrequency,
        o.responsibility                AS PublishedResponsibility,
        o.approval_authority            AS PublishedApprovalAuthority,
        o.retention_requirement         AS PublishedRetention,

        -- Typed detail (224). Whichever array matches TypeCode is what
        -- the admin module actually captured for this obligation.
        COALESCE(td.StateRulesJson,      N'[]') AS StateRulesJson,
        COALESCE(td.ExecutionSpecsJson,  N'[]') AS ExecutionSpecsJson,
        COALESCE(td.AssuranceSpecsJson,  N'[]') AS AssuranceSpecsJson,
        COALESCE(td.EventResponsesJson,  N'[]') AS EventResponsesJson,
        COALESCE(td.ConstraintRulesJson, N'[]') AS ConstraintRulesJson,
        COALESCE(td.RetentionSpecsJson,  N'[]') AS RetentionSpecsJson,
        COALESCE(td.EvidenceJson,        N'[]') AS PublishedEvidenceJson,

        -- As adopted here. NULL until the organization adopts it.
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

        -- What adopting will create, and what already exists.
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
    LEFT   JOIN grac_practice.vw_pm_obligation_typed_detail td
           ON td.ObligationId = pk.obligation_id
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

-- =====================================================================
-- 3. sp_pm_view_obligations_typed -- re-issued
--
--    The 122 body with the seven inline sub-queries replaced by a join
--    to the view. Same result set, same column names, same order --
--    only the source of those seven columns has moved, so that the
--    projection has exactly one definition.
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

-- =====================================================================
-- 4. Verification
-- =====================================================================
PRINT '=== 224 verification ===';

SELECT 'vw_pm_obligation_typed_detail exists' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.vw_pm_obligation_typed_detail','V') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT 'sp_resolve_obligation_list reads the view',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_resolve_obligation_list','P'))
                 LIKE '%vw_pm_obligation_typed_detail%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT 'sp_pm_view_obligations_typed reads the view',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('dbo.sp_pm_view_obligations_typed','P'))
                 LIKE '%vw_pm_obligation_typed_detail%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT 'the projection has one definition',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('dbo.sp_pm_view_obligations_typed','P'))
                 LIKE '%obligation_state_rule%'
            THEN 'FAIL -- 122 sub-queries still inline' ELSE 'PASS' END;

-- How many obligations actually carry typed detail. All zeroes is not a
-- fault of this migration: Control Management 027 back-fills every
-- pre-taxonomy row as Execution with no detail rows, and classifying
-- them is an SME task. The card falls back to the published four in
-- that case.
PRINT '=== Obligations carrying typed detail, by type ===';
SELECT t.type_code AS TypeCode,
       COUNT(*)    AS Obligations,
       SUM(CASE WHEN d.StateRulesJson      <> N'[]' THEN 1 ELSE 0 END) AS WithStateRules,
       SUM(CASE WHEN d.ExecutionSpecsJson  <> N'[]' THEN 1 ELSE 0 END) AS WithExecutionSpecs,
       SUM(CASE WHEN d.AssuranceSpecsJson  <> N'[]' THEN 1 ELSE 0 END) AS WithAssuranceSpecs,
       SUM(CASE WHEN d.EventResponsesJson  <> N'[]' THEN 1 ELSE 0 END) AS WithEventResponses,
       SUM(CASE WHEN d.ConstraintRulesJson <> N'[]' THEN 1 ELSE 0 END) AS WithConstraintRules,
       SUM(CASE WHEN d.RetentionSpecsJson  <> N'[]' THEN 1 ELSE 0 END) AS WithRetentionSpecs,
       SUM(CASE WHEN d.EvidenceJson        <> N'[]' THEN 1 ELSE 0 END) AS WithEvidence
FROM   GRAC_New.requirement_obligation o
LEFT   JOIN GRAC_New.obligation_type_master t ON t.obligation_type_id = o.obligation_type_id
LEFT   JOIN grac_practice.vw_pm_obligation_typed_detail d ON d.ObligationId = o.obligation_id
WHERE  o.status = N'Active'
GROUP  BY t.type_code
ORDER  BY t.type_code;

PRINT '';
PRINT '224 complete. Ship PracticeManagement.Api and PracticeManagement.Web with it.';
GO

SET NOEXEC OFF;
GO
