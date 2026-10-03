-- =====================================================================
-- 394 Repository subscription copy model -- PHASE 2c (repoint readers:
-- obligations, typed detail, evidence)
--
-- Last reader batch of phase 2. After 393 + 394 nothing an organization
-- sees of the obligation catalogue is read live from grac_new; it is the
-- organization's approved copy (391/392). Master / lookup tables
-- (obligation_type_master, evidence_type_master, reference_option,
-- event_type_master) and release headers stay live.
--
-- NEW
--   vw_pm_org_obligation_typed_detail -- (OrganizationId, ObligationId) +
--     the 7 typed JSON columns, from organization_obligation. Same column
--     names and JSON shape as vw_pm_obligation_typed_detail.
--   vw_pm_obligation_typed_detail itself is NOT changed: it stays the
--   grac_new builder that 391's copy source (vw_repo_src_obligation)
--   reads. No screen reads it any more.
--
-- RE-ISSUED (latest migration in brackets; logic unchanged apart from the
-- listed joins)
--   vw_pm_obligation_evidence (144)   now organization-scoped (new first
--                                      column organization_id); every
--                                      consumer below filters on it
--   vw_pm_practice_default_frequency (145),
--   vw_pm_event_driven_obligation (342)
--                                      copy tables; the assurance spec is
--                                      read from the copied AssuranceSpecsJson
--   vw_pm_instance_effective_assurance_frequency (237),
--   vw_pm_instance_schedulable_obligations (337),
--   dbo.sp_pm_view_obligations_typed (301)
--                                      typed detail -> org view
--   sp_resolve_evidence_reconcile_for_instance (304),
--   sp_resolve_obligation_adopt (304), sp_resolve_evidence_list (306),
--   sp_resolve_instance_list (315), sp_resolve_obligation_list (353)
--                                      fn_org_* / org-filtered views
--
-- Phase 2 is complete with this file. It must ship together with phase
-- 3 (change detection + approval): from now on nothing Control Management
-- publishes reaches an organization until it is approved.
--
-- SAFE TO RE-RUN. Requires 391, 392, 393.
-- Rollback: 394_repository_copy_phase2_obligations_rollback.sql
-- ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID('grac_practice.organization_obligation','U') IS NULL
   OR OBJECT_ID('grac_practice.organization_obligation_evidence','U') IS NULL
   OR OBJECT_ID('grac_practice.organization_obligation_requirement_map','U') IS NULL
   OR OBJECT_ID('grac_practice.organization_repository_requirement','U') IS NULL
   OR OBJECT_ID('grac_practice.fn_org_requirement_obligation','IF') IS NULL
   OR OBJECT_ID('grac_practice.fn_org_obligation_requirement_release_map','IF') IS NULL
   OR OBJECT_ID('grac_practice.fn_org_requirement_obligation_evidence','IF') IS NULL
   OR OBJECT_ID('grac_practice.fn_org_requirement','IF') IS NULL
   OR COL_LENGTH('grac_practice.organization_obligation','assurance_specs_json') IS NULL
   OR COL_LENGTH('grac_practice.organization_obligation','evidence_json') IS NULL
BEGIN
    PRINT 'ABORT (394): run 391, 392 and 393 first.';
    SET NOEXEC ON;
END
GO

-- ---------------------------------------------------------------------
-- vw_pm_org_obligation_typed_detail (new)
-- ---------------------------------------------------------------------
CREATE OR ALTER VIEW grac_practice.vw_pm_org_obligation_typed_detail
AS
    -- 394: the organization's approved copy of vw_pm_obligation_typed_detail.
    -- Consumers join on (OrganizationId, ObligationId).
    SELECT oo.organization_id                         AS OrganizationId,
           oo.obligation_id                           AS ObligationId,
           COALESCE(oo.state_rules_json,      N'[]')  AS StateRulesJson,
           COALESCE(oo.execution_specs_json,  N'[]')  AS ExecutionSpecsJson,
           COALESCE(oo.assurance_specs_json,  N'[]')  AS AssuranceSpecsJson,
           COALESCE(oo.event_responses_json,  N'[]')  AS EventResponsesJson,
           COALESCE(oo.constraint_rules_json, N'[]')  AS ConstraintRulesJson,
           COALESCE(oo.retention_specs_json,  N'[]')  AS RetentionSpecsJson,
           COALESCE(oo.evidence_json,         N'[]')  AS EvidenceJson
    FROM   grac_practice.organization_obligation oo;
GO

-- ---------------------------------------------------------------------
-- vw_pm_obligation_evidence (from 144)
-- ---------------------------------------------------------------------
CREATE OR ALTER VIEW grac_practice.vw_pm_obligation_evidence
AS
    -- 394: the organization's approved copy (organization_obligation_evidence),
    -- one row per (organization, obligation, evidence, source). Consumers
    -- MUST filter on organization_id.
    --   Direct = the evidence row is stamped with the obligation
    --            (requirement_obligation_evidence.obligation_id).
    --   Link   = the obligation's copied EvidenceJson lists it through a
    --            per-type link table (as resolved by 302).
    -- Only evidence that was Active when copied is in the copy (144's
    -- Direct branch had no status filter; consumers filtered status).
    SELECT e.organization_id,
           e.obligation_id,
           e.obligation_evidence_id,
           e.evidence_type_id,
           e.retention_requirement,
           N'Direct' AS Source
    FROM   grac_practice.organization_obligation_evidence e
    WHERE  e.obligation_id IS NOT NULL
    UNION
    SELECT oo.organization_id,
           oo.obligation_id,
           e.obligation_evidence_id,
           e.evidence_type_id,
           e.retention_requirement,
           N'Link' AS Source
    FROM   grac_practice.organization_obligation oo
    CROSS APPLY OPENJSON(oo.evidence_json)
           WITH (Source NVARCHAR(20) '$.Source',
                 ObligationEvidenceId BIGINT '$.ObligationEvidenceId') j
    JOIN   grac_practice.organization_obligation_evidence e
           ON e.organization_id = oo.organization_id
          AND e.obligation_evidence_id = j.ObligationEvidenceId
    WHERE  j.Source = N'Link';
GO

-- ---------------------------------------------------------------------
-- vw_pm_practice_default_frequency (from 145)
-- ---------------------------------------------------------------------
CREATE OR ALTER VIEW grac_practice.vw_pm_practice_default_frequency
AS
    WITH reachable AS (
        SELECT DISTINCT
               p.practice_id,
               p.organization_id,
               orm.obligation_id
        FROM   grac_practice.practice p
        JOIN   grac_practice.organization_requirement req
               ON req.organization_requirement_id = p.organization_requirement_id
        -- 394: the organization's approved copy.
        LEFT   JOIN grac_practice.organization_repository_requirement repo_req
               ON repo_req.organization_id = p.organization_id
              AND repo_req.requirement_code = req.requirement_code AND repo_req.status = N'Active'
        JOIN   grac_practice.organization_obligation_requirement_map orm
               ON orm.organization_id = p.organization_id
              AND orm.requirement_id = COALESCE(req.repository_requirement_id, repo_req.requirement_id)
              AND orm.status = N'Active'
        WHERE  EXISTS (SELECT 1 FROM grac_practice.repository_subscription s
                        WHERE s.organization_id = p.organization_id
                          AND s.release_id = orm.release_id
                          AND s.status = N'Active')
    ),
    -- Published labels, execution and assurance, mapped to the practice
    -- catalog by name.
    labelled AS (
        SELECT r.practice_id,
               N'Execution' AS Kind,
               COALESCE(ef.option_label, o.frequency_type) AS FrequencyLabel
        FROM   reachable r
        JOIN   grac_practice.organization_obligation o
               ON o.organization_id = r.organization_id
              AND o.obligation_id = r.obligation_id AND o.status = N'Active'
        LEFT   JOIN GRAC_New.reference_option ef
               ON ef.reference_option_id = o.execution_frequency_id
        UNION ALL
        SELECT r.practice_id,
               N'Assurance' AS Kind,
               af.option_label AS FrequencyLabel
        FROM   reachable r
        -- 394: Active assurance specs as copied (AssuranceSpecsJson of 302).
        JOIN   grac_practice.organization_obligation oo
               ON oo.organization_id = r.organization_id
              AND oo.obligation_id = r.obligation_id
        CROSS APPLY OPENJSON(oo.assurance_specs_json)
               WITH (assurance_frequency_id BIGINT '$.assurance_frequency_id') spec
        JOIN   GRAC_New.reference_option af
               ON af.reference_option_id = spec.assurance_frequency_id
    ),
    matched AS (
        SELECT l.practice_id,
               l.Kind,
               fm.frequency_id,
               fm.frequency_name,
               fm.display_order,
               -- Periodic first; a trigger is only a fallback.
               CASE WHEN fm.frequency_name IN (N'Event Driven', N'Continuous', N'Custom')
                    THEN 1 ELSE 0 END AS IsNonPeriodic
        FROM   labelled l
        JOIN   grac_practice.frequency_master fm
               ON fm.frequency_name = l.FrequencyLabel
              AND fm.is_active = 1
        WHERE  NULLIF(LTRIM(RTRIM(ISNULL(l.FrequencyLabel, N''))), N'') IS NOT NULL
    ),
    ranked AS (
        SELECT practice_id, Kind, frequency_id, frequency_name,
               ROW_NUMBER() OVER (PARTITION BY practice_id, Kind
                                  ORDER BY IsNonPeriodic, display_order, frequency_id) AS rn
        FROM   matched
    )
    SELECT practice_id                                                     AS PracticeId,
           MAX(CASE WHEN Kind = N'Execution' THEN frequency_id   END)      AS ExecutionFrequencyId,
           MAX(CASE WHEN Kind = N'Execution' THEN frequency_name END)      AS ExecutionFrequency,
           MAX(CASE WHEN Kind = N'Assurance' THEN frequency_id   END)      AS AssuranceFrequencyId,
           MAX(CASE WHEN Kind = N'Assurance' THEN frequency_name END)      AS AssuranceFrequency
    FROM   ranked
    WHERE  rn = 1
    GROUP  BY practice_id;
GO

-- ---------------------------------------------------------------------
-- vw_pm_event_driven_obligation (from 342)
-- ---------------------------------------------------------------------
CREATE OR ALTER VIEW grac_practice.vw_pm_event_driven_obligation
AS
    SELECT DISTINCT
        req.organization_id,
        req.organization_requirement_id,
        req.requirement_code,
        req.requirement_name,
        req.applicability_status                                   AS RequirementApplicability,
        p.practice_id,
        p.practice_code,
        p.practice_name,
        p.applicability_status                                     AS PracticeApplicability,
        orm.release_id,
        o.obligation_id,
        COALESCE(NULLIF(LTRIM(RTRIM(o.obligation_name)), N''),
                 LEFT(o.obligation_text, 300))                     AS obligation_label,
        o.obligation_text,
        spec.trigger_mode,
        spec.event_type_id,
        et.event_code                                              AS event_type_code,
        et.event_name                                              AS event_type_name,
        et.subject_entity,
        CAST(CASE WHEN EXISTS (
                 SELECT 1 FROM grac_practice.repository_subscription s
                  WHERE s.organization_id     = req.organization_id
                    AND s.release_id          = orm.release_id
                    AND s.subscription_status = N'Active'
                    AND s.status              = N'Active')
             THEN 1 ELSE 0 END AS BIT)                             AS is_subscribed,
        -- Migration 341/342: which local identity this row carries. NULL
        -- on every catalog row -- a catalog obligation's identity is
        -- obligation_id, the column two lines above.
        CAST(NULL AS BIGINT)                                       AS local_practice_obligation_id,
        CAST(NULL AS BIGINT)                                       AS local_instance_obligation_id
    FROM       grac_practice.organization_requirement req
    LEFT JOIN  grac_practice.practice p
           ON  p.organization_requirement_id = req.organization_requirement_id
          AND  p.organization_id             = req.organization_id
          AND  p.status                      = N'Active'
    -- 394: the organization's approved copy; the assurance spec is the
    -- copied AssuranceSpecsJson (Active specs only, as 302 builds it).
    LEFT JOIN  grac_practice.organization_repository_requirement repo_req
           ON  repo_req.organization_id  = req.organization_id
          AND  repo_req.requirement_code = req.requirement_code
          AND  repo_req.status           = N'Active'
    JOIN       grac_practice.organization_obligation_requirement_map orm
           ON  orm.organization_id = req.organization_id
          AND  orm.requirement_id  = COALESCE(req.repository_requirement_id, repo_req.requirement_id)
          AND  orm.status          = N'Active'
    JOIN       grac_practice.organization_obligation o
           ON  o.organization_id = req.organization_id
          AND  o.obligation_id   = orm.obligation_id
    CROSS APPLY OPENJSON(o.assurance_specs_json)
           WITH (trigger_mode  NVARCHAR(60) '$.trigger_mode',
                 event_type_id BIGINT       '$.event_type_id') spec
    JOIN       GRAC_New.event_type_master et
           ON  et.event_type_id = spec.event_type_id
          AND  et.status        = N'Active'
    -- trigger_mode is stored as the CODE by ControlManagement 033.
    WHERE      spec.trigger_mode = N'EventDriven'
      AND      req.status        = N'Active'

    -- =================================================================
    -- Branch 2: practice-level custom obligations (307), declared
    -- event-driven (340). One row per DEFINITION, not per fanned-out
    -- copy -- see the migration header.
    -- =================================================================
    UNION ALL
    SELECT DISTINCT
        po.organization_id,
        CAST(NULL AS BIGINT)                                       AS organization_requirement_id,
        NULL                                                       AS requirement_code,
        NULL                                                       AS requirement_name,
        NULL                                                       AS RequirementApplicability,
        pr.practice_id,
        pr.practice_code,
        pr.practice_name,
        pr.applicability_status                                    AS PracticeApplicability,
        CAST(NULL AS BIGINT)                                       AS release_id,
        CAST(NULL AS BIGINT)                                       AS obligation_id,
        COALESCE(NULLIF(LTRIM(RTRIM(po.obligation_name)), N''),
                 LEFT(po.obligation_description, 300))             AS obligation_label,
        po.obligation_description                                  AS obligation_text,
        N'EventDriven'                                             AS trigger_mode,
        po.event_type_id,
        et.event_code                                              AS event_type_code,
        et.event_name                                              AS event_type_name,
        et.subject_entity,
        CAST(1 AS BIT)                                              AS is_subscribed,
        po.practice_obligation_id                                  AS local_practice_obligation_id,
        CAST(NULL AS BIGINT)                                       AS local_instance_obligation_id
    FROM       grac_practice.practice_obligation po
    JOIN       grac_practice.practice pr
           ON  pr.practice_id = po.practice_id
          AND  pr.status      = N'Active'
    JOIN       GRAC_New.event_type_master et
           ON  et.event_type_id = po.event_type_id
          AND  et.status        = N'Active'
    WHERE      po.event_type_id IS NOT NULL
      AND      po.status        = N'Active'

    -- =================================================================
    -- Branch 3: instance-only custom obligations (227) -- not cataloged,
    -- not a practice-level copy (that population is branch 2), declared
    -- event-driven (340).
    -- =================================================================
    UNION ALL
    SELECT DISTINCT
        pio.organization_id,
        CAST(NULL AS BIGINT)                                       AS organization_requirement_id,
        NULL                                                       AS requirement_code,
        NULL                                                       AS requirement_name,
        NULL                                                       AS RequirementApplicability,
        pi.practice_id,
        pr.practice_code,
        pr.practice_name,
        pr.applicability_status                                    AS PracticeApplicability,
        CAST(NULL AS BIGINT)                                       AS release_id,
        CAST(NULL AS BIGINT)                                       AS obligation_id,
        COALESCE(NULLIF(LTRIM(RTRIM(pio.obligation_name)), N''),
                 LEFT(pio.obligation_description, 300))            AS obligation_label,
        pio.obligation_description                                 AS obligation_text,
        N'EventDriven'                                             AS trigger_mode,
        pio.event_type_id,
        et.event_code                                              AS event_type_code,
        et.event_name                                              AS event_type_name,
        et.subject_entity,
        CAST(1 AS BIT)                                              AS is_subscribed,
        CAST(NULL AS BIGINT)                                       AS local_practice_obligation_id,
        pio.practice_instance_obligation_id                        AS local_instance_obligation_id
    FROM       grac_practice.practice_instance_obligation pio
    JOIN       grac_practice.practice_instance pi
           ON  pi.practice_instance_id = pio.practice_instance_id
          AND  pi.status               = N'Active'
    JOIN       grac_practice.practice pr
           ON  pr.practice_id = pi.practice_id
          AND  pr.status      = N'Active'
    JOIN       GRAC_New.event_type_master et
           ON  et.event_type_id = pio.event_type_id
          AND  et.status        = N'Active'
    WHERE      pio.obligation_id                  IS NULL
      AND      pio.source_practice_obligation_id   IS NULL
      AND      pio.event_type_id                   IS NOT NULL
      AND      pio.status                          = N'Active';
GO

-- ---------------------------------------------------------------------
-- vw_pm_instance_effective_assurance_frequency (from 237)
-- ---------------------------------------------------------------------
CREATE OR ALTER VIEW grac_practice.vw_pm_instance_effective_assurance_frequency
AS
    WITH per_obligation AS (
        -- The effective assurance frequency for each Assurance obligation
        -- on each active instance. NULL if none of the three sources
        -- names one -- for example an EventDriven Assurance with no
        -- assurance_frequency_id anywhere. Those obligations drop out
        -- during the rank because the WHERE below excludes NULLs.
        SELECT pio.practice_instance_id,
               pio.practice_instance_obligation_id,
               COALESCE(
                   pio.assurance_frequency_id,
                   TRY_CAST(JSON_VALUE(pio.typed_detail_json, N'$[0].assurance_frequency_id') AS INT),
                   pub.published_assurance_frequency_id
               ) AS assurance_frequency_id
        FROM   grac_practice.practice_instance_obligation pio
        OUTER  APPLY (
            -- Published spec, if this is an adopted obligation. The
            -- typed-detail view emits AssuranceSpecsJson from the
            -- assurance_spec table, so its first row's frequency id is
            -- what the authority wrote.
            SELECT TRY_CAST(JSON_VALUE(td.AssuranceSpecsJson, N'$[0].assurance_frequency_id') AS INT)
                       AS published_assurance_frequency_id
            FROM   grac_practice.vw_pm_org_obligation_typed_detail td
            WHERE  td.OrganizationId = pio.organization_id
              AND  td.ObligationId = pio.obligation_id
        ) pub
        WHERE  pio.status               = N'Active'
          AND  pio.obligation_type_code = N'Assurance'
    ),
    resolved AS (
        SELECT o.practice_instance_id,
               o.assurance_frequency_id,
               fm.frequency_name,
               fm.display_order,
               -- Periodic cadence in days. NULL for non-periodic ones so
               -- they rank last, regardless of frequency_value.
               CASE
                 WHEN fm.frequency_name IN (N'Event Driven', N'Continuous', N'Custom')
                      THEN NULL
                 WHEN fm.frequency_value IS NULL OR fm.frequency_unit IS NULL
                      THEN NULL
                 ELSE fm.frequency_value
                      * CASE UPPER(LTRIM(RTRIM(fm.frequency_unit)))
                             WHEN N'DAY'     THEN 1
                             WHEN N'DAYS'    THEN 1
                             WHEN N'WEEK'    THEN 7
                             WHEN N'WEEKS'   THEN 7
                             WHEN N'MONTH'   THEN 30
                             WHEN N'MONTHS'  THEN 30
                             WHEN N'QUARTER' THEN 90
                             WHEN N'QUARTERS'THEN 90
                             WHEN N'YEAR'    THEN 365
                             WHEN N'YEARS'   THEN 365
                             ELSE NULL
                        END
               END AS periodic_days
        FROM   per_obligation o
        JOIN   grac_practice.frequency_master fm
               ON fm.frequency_id = o.assurance_frequency_id
              AND fm.is_active    = 1
        WHERE  o.assurance_frequency_id IS NOT NULL
    ),
    ranked AS (
        SELECT practice_instance_id, assurance_frequency_id, frequency_name,
               ROW_NUMBER() OVER (
                   PARTITION BY practice_instance_id
                   ORDER BY CASE WHEN periodic_days IS NULL THEN 1 ELSE 0 END,
                            periodic_days,
                            display_order,
                            assurance_frequency_id
               ) AS rn
        FROM   resolved
    )
    SELECT r.practice_instance_id                                          AS PracticeInstanceId,
           MAX(CASE WHEN r.rn = 1 THEN r.assurance_frequency_id END)       AS AssuranceFrequencyId,
           MAX(CASE WHEN r.rn = 1 THEN r.frequency_name         END)       AS AssuranceFrequency,
           COUNT(DISTINCT r.assurance_frequency_id)                        AS DistinctFrequencyCount,
           COUNT(*)                                                        AS ObligationCount
    FROM   ranked r
    GROUP  BY r.practice_instance_id;
GO

-- ---------------------------------------------------------------------
-- vw_pm_instance_schedulable_obligations (from 337)
-- ---------------------------------------------------------------------
CREATE OR ALTER VIEW grac_practice.vw_pm_instance_schedulable_obligations
AS
    WITH candidate AS (
        -- Execution obligations: frequency from the execution column /
        -- typed detail / published execution spec.
        SELECT pio.practice_instance_id            AS PracticeInstanceId,
               pio.practice_instance_obligation_id  AS PracticeInstanceObligationId,
               pio.obligation_id                    AS ObligationId,
               N'Execution'                         AS ScheduleKind,
               COALESCE(
                   pio.execution_frequency_id,
                   TRY_CAST(JSON_VALUE(pio.typed_detail_json, N'$[0].execution_frequency_id') AS INT),
                   TRY_CAST(JSON_VALUE(td.ExecutionSpecsJson, N'$[0].execution_frequency_id') AS INT)
               )                                    AS FrequencyId
        FROM   grac_practice.practice_instance_obligation pio
        LEFT   JOIN grac_practice.vw_pm_org_obligation_typed_detail td
               ON td.OrganizationId = pio.organization_id
              AND td.ObligationId = pio.obligation_id
        WHERE  pio.status               = N'Active'
          AND  pio.obligation_type_code = N'Execution'

        UNION ALL

        -- Assurance obligations: frequency from the assurance column /
        -- typed detail / published assurance spec.
        SELECT pio.practice_instance_id,
               pio.practice_instance_obligation_id,
               pio.obligation_id,
               N'Assurance',
               COALESCE(
                   pio.assurance_frequency_id,
                   TRY_CAST(JSON_VALUE(pio.typed_detail_json, N'$[0].assurance_frequency_id') AS INT),
                   TRY_CAST(JSON_VALUE(td.AssuranceSpecsJson, N'$[0].assurance_frequency_id') AS INT)
               )
        FROM   grac_practice.practice_instance_obligation pio
        LEFT   JOIN grac_practice.vw_pm_org_obligation_typed_detail td
               ON td.OrganizationId = pio.organization_id
              AND td.ObligationId = pio.obligation_id
        WHERE  pio.status               = N'Active'
          AND  pio.obligation_type_code = N'Assurance'
    )
    SELECT c.PracticeInstanceId,
           c.PracticeInstanceObligationId,
           c.ObligationId,
           c.ScheduleKind,
           c.FrequencyId,
           fm.frequency_name AS FrequencyName
    FROM   candidate c
    JOIN   grac_practice.frequency_master fm
           ON fm.frequency_id = c.FrequencyId
          AND fm.is_active    = 1
    WHERE  c.FrequencyId IS NOT NULL
      -- Periodic only: a real recurring cadence. Non-periodic frequencies
      -- (Event Driven / Continuous / Custom, or a row with no value/unit)
      -- do not schedule.
      AND  fm.frequency_name NOT IN (N'Event Driven', N'Continuous', N'Custom')
      AND  fm.frequency_value IS NOT NULL
      AND  fm.frequency_unit  IS NOT NULL;
GO

-- ---------------------------------------------------------------------
-- sp_pm_view_obligations_typed (from 301)
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
        COALESCE(td.EvidenceJson,        N'[]') AS EvidenceJson
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

-- ---------------------------------------------------------------------
-- sp_resolve_evidence_reconcile_for_instance (from 304)
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE grac_practice.sp_resolve_evidence_reconcile_for_instance
    @practice_instance_id BIGINT,
    @actor                NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;

    IF @practice_instance_id IS NULL
        THROW 52630, 'sp_resolve_evidence_reconcile_for_instance: practice_instance_id is required.', 1;

    DECLARE @organization_id BIGINT;
    SELECT @organization_id = organization_id
    FROM   grac_practice.practice_instance
    WHERE  practice_instance_id = @practice_instance_id;

    -- RETURN, not THROW. This runs on a read path, and an instance that has
    -- been retired between the page loading and this call must not turn the
    -- workspace into an error.
    IF @organization_id IS NULL RETURN;

    DECLARE @active_record_status_id INT = (
        SELECT TOP 1 record_status_id FROM grac_practice.record_status_master
        WHERE status_code = 'ACTIVE' OR status_name = 'Active' ORDER BY record_status_id);
    IF @active_record_status_id IS NULL
        THROW 52609, 'sp_resolve_evidence_reconcile_for_instance: record status master data is missing.', 1;

    DECLARE @collection_method_id INT = (
        SELECT TOP 1 collection_method_id FROM grac_practice.collection_method_master
        WHERE is_active = 1 AND (collection_method_code = N'Manual' OR collection_method_name = N'Manual')
        ORDER BY collection_method_id);
    IF @collection_method_id IS NULL
        SELECT TOP 1 @collection_method_id = collection_method_id
        FROM grac_practice.collection_method_master WHERE is_active = 1
        ORDER BY display_order, collection_method_id;
    IF @collection_method_id IS NULL
        THROW 52610, 'sp_resolve_evidence_reconcile_for_instance: collection method master data is missing.', 1;

    DECLARE @inherited_alignment_id INT = (
        SELECT TOP 1 alignment_status_id FROM grac_practice.evidence_alignment_status_master
        WHERE is_active = 1 AND alignment_status_code = N'Inherited'
        ORDER BY alignment_status_id);
    IF @inherited_alignment_id IS NULL
        SELECT TOP 1 @inherited_alignment_id = alignment_status_id
        FROM grac_practice.evidence_alignment_status_master WHERE is_active = 1
        ORDER BY display_order, alignment_status_id;
    IF @inherited_alignment_id IS NULL
        THROW 52611, 'sp_resolve_evidence_reconcile_for_instance: evidence alignment status master data is missing.', 1;

    -- The driving set. This is the ONLY difference from the block that used
    -- to live in sp_resolve_obligation_adopt: there it came from the call's
    -- JSON payload (@req WHERE IsAdopted = 1), here it is what the instance
    -- has actually adopted.
    --
    -- obligation_id > 0 keeps organization-defined obligations out: their
    -- evidence is matched on source_practice_instance_obligation_id
    -- (migrations 231/232), not through the repository view below.
    DECLARE @adopted TABLE (ObligationId BIGINT PRIMARY KEY);

    INSERT INTO @adopted (ObligationId)
    SELECT DISTINCT pio.obligation_id
    FROM   grac_practice.practice_instance_obligation pio
    WHERE  pio.practice_instance_id = @practice_instance_id
      AND  pio.status = N'Active'
      AND  pio.obligation_id > 0;

    IF NOT EXISTS (SELECT 1 FROM @adopted) RETURN;

    UPDATE pie
       SET source_obligation_id = x.ObligationId,
           updated_by           = @actor,
           updated_dt           = SYSUTCDATETIME()
    FROM   grac_practice.practice_instance_evidence pie
    CROSS  APPLY (
        SELECT TOP 1 r.ObligationId
        FROM   @adopted r
        JOIN   grac_practice.vw_pm_obligation_evidence oe ON oe.organization_id = @organization_id AND oe.obligation_id = r.ObligationId
        JOIN   GRAC_New.evidence_type_master get ON get.evidence_type_id = oe.evidence_type_id
        JOIN   grac_practice.evidence_type_master pet
               ON pet.evidence_type_name = get.evidence_type_name AND pet.is_active = 1
        WHERE  pet.evidence_type_id = pie.evidence_type_id
        ORDER  BY r.ObligationId
    ) x
    WHERE  pie.practice_instance_id = @practice_instance_id
      AND  pie.status = N'Active'
      AND  pie.source_obligation_id IS NULL;

    INSERT grac_practice.practice_instance_evidence
        (organization_id, practice_instance_id, evidence_type_id,
         inherited_from_repository, organization_modified, is_mandatory,
         collection_method_id, collection_frequency_id, retention_period,
         alignment_status_id, source_obligation_id, source_obligation_evidence_id,
         status, record_status_id, entered_by)
    SELECT @organization_id, @practice_instance_id, s.evidence_type_id,
           1, 0, 1,
           @collection_method_id, NULL, s.retention_requirement,
           @inherited_alignment_id, s.ObligationId, s.obligation_evidence_id,
           N'Active', @active_record_status_id, @actor
    FROM (
        SELECT r.ObligationId,
               pet.evidence_type_id,
               MIN(oe.obligation_evidence_id) AS obligation_evidence_id,
               MIN(oe.retention_requirement)  AS retention_requirement
        FROM   @adopted r
        JOIN   grac_practice.vw_pm_obligation_evidence oe ON oe.organization_id = @organization_id AND oe.obligation_id = r.ObligationId
        JOIN   GRAC_New.evidence_type_master get ON get.evidence_type_id = oe.evidence_type_id
        JOIN   grac_practice.evidence_type_master pet
               ON pet.evidence_type_name = get.evidence_type_name AND pet.is_active = 1
        GROUP  BY r.ObligationId, pet.evidence_type_id
    ) s
    WHERE NOT EXISTS (SELECT 1 FROM grac_practice.practice_instance_evidence x
                       WHERE x.practice_instance_id = @practice_instance_id
                         AND x.evidence_type_id     = s.evidence_type_id
                         AND x.source_obligation_id = s.ObligationId
                         AND x.status = N'Active');
END
GO

-- ---------------------------------------------------------------------
-- sp_resolve_obligation_adopt (from 304)
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE grac_practice.sp_resolve_obligation_adopt
    @practice_instance_id BIGINT,
    @payload_json         NVARCHAR(MAX),
    @actor                NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @practice_instance_id IS NULL
        THROW 52606, 'sp_resolve_obligation_adopt: practice_instance_id is required.', 1;
    IF @payload_json IS NULL OR ISJSON(@payload_json) <> 1
        THROW 52607, 'sp_resolve_obligation_adopt: payload must be a JSON array.', 1;

    DECLARE @organization_id BIGINT;
    SELECT @organization_id = organization_id
    FROM   grac_practice.practice_instance
    WHERE  practice_instance_id = @practice_instance_id;

    IF @organization_id IS NULL
        THROW 52608, 'sp_resolve_obligation_adopt: instance not found.', 1;

    DECLARE @active_record_status_id INT = (
        SELECT TOP 1 record_status_id FROM grac_practice.record_status_master
        WHERE status_code = 'ACTIVE' OR status_name = 'Active' ORDER BY record_status_id);
    IF @active_record_status_id IS NULL
        THROW 52609, 'sp_resolve_obligation_adopt: record status master data is missing.', 1;

    DECLARE @collection_method_id INT = (
        SELECT TOP 1 collection_method_id FROM grac_practice.collection_method_master
        WHERE is_active = 1 AND (collection_method_code = N'Manual' OR collection_method_name = N'Manual')
        ORDER BY collection_method_id);
    IF @collection_method_id IS NULL
        SELECT TOP 1 @collection_method_id = collection_method_id
        FROM grac_practice.collection_method_master WHERE is_active = 1
        ORDER BY display_order, collection_method_id;
    IF @collection_method_id IS NULL
        THROW 52610, 'sp_resolve_obligation_adopt: collection method master data is missing.', 1;

    DECLARE @inherited_alignment_id INT = (
        SELECT TOP 1 alignment_status_id FROM grac_practice.evidence_alignment_status_master
        WHERE is_active = 1 AND alignment_status_code = N'Inherited'
        ORDER BY alignment_status_id);
    IF @inherited_alignment_id IS NULL
        SELECT TOP 1 @inherited_alignment_id = alignment_status_id
        FROM grac_practice.evidence_alignment_status_master WHERE is_active = 1
        ORDER BY display_order, alignment_status_id;
    IF @inherited_alignment_id IS NULL
        THROW 52611, 'sp_resolve_obligation_adopt: evidence alignment status master data is missing.', 1;

    DECLARE @req TABLE (
        ObligationId          BIGINT PRIMARY KEY,
        IsAdopted             BIT,
        ExecutionFrequencyId  INT NULL,
        ExecutionFrequency    NVARCHAR(120) NULL,
        AssuranceFrequencyId  INT NULL,
        AssuranceFrequency    NVARCHAR(120) NULL,
        Responsibility        NVARCHAR(300) NULL,
        ApprovalAuthority     NVARCHAR(300) NULL,
        RetentionPeriod       NVARCHAR(120) NULL,
        AssuranceType         NVARCHAR(40)  NULL,
        Remarks               NVARCHAR(MAX) NULL,
        EventTypeId           BIGINT        NULL,
        SlaValue              INT           NULL,
        SlaUnit               NVARCHAR(20)  NULL,
        ImplementationStatusId INT          NULL,
        -- Migration 244: Automated-only connection payload. Absent keys
        -- stay NULL (COALESCE below preserves whatever is stored) so a
        -- caller who does not touch these fields does not blank them.
        ConnectionTypeId      INT           NULL,
        ConnectionUrl         NVARCHAR(500) NULL,
        PubExecutionFrequency NVARCHAR(120) NULL,
        PubResponsibility     NVARCHAR(300) NULL,
        PubApprovalAuthority  NVARCHAR(300) NULL,
        PubRetention          NVARCHAR(120) NULL,
        ObligationName        NVARCHAR(500) NULL,
        ObligationTypeCode    NVARCHAR(60)  NULL,
        ReleaseId             BIGINT NULL,
        IsModified            BIT NULL
    );

    INSERT INTO @req (ObligationId, IsAdopted, ExecutionFrequencyId, ExecutionFrequency,
                      AssuranceFrequencyId, AssuranceFrequency, Responsibility,
                      ApprovalAuthority, RetentionPeriod, AssuranceType, Remarks,
                      EventTypeId, SlaValue, SlaUnit, ImplementationStatusId,
                      ConnectionTypeId, ConnectionUrl)
    SELECT j.ObligationId,
           ISNULL(j.IsAdopted, 0),
           j.ExecutionFrequencyId, NULLIF(LTRIM(RTRIM(j.ExecutionFrequency)), N''),
           j.AssuranceFrequencyId, NULLIF(LTRIM(RTRIM(j.AssuranceFrequency)), N''),
           NULLIF(LTRIM(RTRIM(j.Responsibility)), N''),
           NULLIF(LTRIM(RTRIM(j.ApprovalAuthority)), N''),
           NULLIF(LTRIM(RTRIM(j.RetentionPeriod)), N''),
           NULLIF(LTRIM(RTRIM(j.AssuranceType)), N''),
           NULLIF(LTRIM(RTRIM(j.Remarks)), N''),
           j.EventTypeId,
           j.SlaValue,
           NULLIF(LTRIM(RTRIM(j.SlaUnit)), N''),
           j.ImplementationStatusId,
           j.ConnectionTypeId,
           NULLIF(LTRIM(RTRIM(j.ConnectionUrl)), N'')
    FROM OPENJSON(@payload_json) WITH (
        ObligationId         BIGINT        '$.obligationId',
        IsAdopted            BIT           '$.isAdopted',
        ExecutionFrequencyId INT           '$.executionFrequencyId',
        ExecutionFrequency   NVARCHAR(120) '$.executionFrequency',
        AssuranceFrequencyId INT           '$.assuranceFrequencyId',
        AssuranceFrequency   NVARCHAR(120) '$.assuranceFrequency',
        Responsibility       NVARCHAR(300) '$.responsibility',
        ApprovalAuthority    NVARCHAR(300) '$.approvalAuthority',
        RetentionPeriod      NVARCHAR(120) '$.retentionPeriod',
        AssuranceType        NVARCHAR(40)  '$.assuranceType',
        Remarks              NVARCHAR(MAX) '$.remarks',
        EventTypeId          BIGINT        '$.eventTypeId',
        SlaValue             INT           '$.slaValue',
        SlaUnit              NVARCHAR(20)  '$.slaUnit',
        ImplementationStatusId INT         '$.implementationStatusId',
        ConnectionTypeId     INT           '$.connectionTypeId',
        ConnectionUrl        NVARCHAR(500) '$.connectionUrl'
    ) j
    WHERE j.ObligationId IS NOT NULL;

    IF NOT EXISTS (SELECT 1 FROM @req)
        THROW 52612, 'sp_resolve_obligation_adopt: no obligations were supplied.', 1;

    -- Reject a connection_type_id that does not exist, so a stale UI
    -- cache never writes a broken FK. NULL is fine (Manual assurance,
    -- or user simply hasn't picked one yet).
    IF EXISTS (SELECT 1 FROM @req r
                WHERE r.ConnectionTypeId IS NOT NULL
                  AND NOT EXISTS (SELECT 1 FROM grac_practice.connection_type_master c
                                   WHERE c.connection_type_id = r.ConnectionTypeId
                                     AND c.is_active = 1))
        THROW 52675, 'sp_resolve_obligation_adopt: unknown connection type.', 1;

    UPDATE r
       SET PubExecutionFrequency = COALESCE(ef.option_label, o.frequency_type),
           PubResponsibility     = o.responsibility,
           PubApprovalAuthority  = o.approval_authority,
           PubRetention          = o.retention_requirement,
           ObligationName        = COALESCE(NULLIF(LTRIM(RTRIM(o.obligation_name)), N''),
                                            LEFT(o.obligation_text, 300)),
           ObligationTypeCode    = t.type_code
    FROM  @req r
    JOIN  grac_practice.fn_org_requirement_obligation(@organization_id) o ON o.obligation_id = r.ObligationId
    LEFT  JOIN GRAC_New.obligation_type_master t ON t.obligation_type_id = o.obligation_type_id
    LEFT  JOIN GRAC_New.reference_option ef ON ef.reference_option_id = o.execution_frequency_id;

    UPDATE r
       SET ReleaseId = x.release_id
    FROM  @req r
    CROSS APPLY (
        SELECT MIN(orm.release_id) AS release_id
        FROM   grac_practice.fn_org_obligation_requirement_release_map(@organization_id) orm
        WHERE  orm.obligation_id = r.ObligationId
          AND  orm.status = N'Active'
          AND  EXISTS (SELECT 1 FROM grac_practice.repository_subscription s
                        WHERE s.organization_id = @organization_id
                          AND s.release_id = orm.release_id
                          AND s.status = N'Active')
    ) x;

    UPDATE @req
       SET IsModified = CASE
             WHEN (ExecutionFrequency  IS NOT NULL AND ISNULL(ExecutionFrequency, N'')  <> ISNULL(PubExecutionFrequency, N''))
               OR (ExecutionFrequencyId IS NOT NULL)
               OR (AssuranceFrequency  IS NOT NULL) OR (AssuranceFrequencyId IS NOT NULL)
               OR (Responsibility      IS NOT NULL AND ISNULL(Responsibility, N'')      <> ISNULL(PubResponsibility, N''))
               OR (ApprovalAuthority   IS NOT NULL AND ISNULL(ApprovalAuthority, N'')   <> ISNULL(PubApprovalAuthority, N''))
               OR (RetentionPeriod     IS NOT NULL AND ISNULL(RetentionPeriod, N'')     <> ISNULL(PubRetention, N''))
               OR (AssuranceType       IS NOT NULL)
               OR (Remarks             IS NOT NULL)
               OR (EventTypeId         IS NOT NULL)
               OR (SlaValue            IS NOT NULL)
               OR (SlaUnit             IS NOT NULL)
               OR (ImplementationStatusId IS NOT NULL)
               -- Migration 244: connection info is always an
               -- organisation-side answer (nothing is published), so any
               -- value here flips the row to modified.
               OR (ConnectionTypeId    IS NOT NULL)
               OR (ConnectionUrl       IS NOT NULL)
             THEN 1 ELSE 0 END;

    BEGIN TRAN;

    MERGE grac_practice.practice_instance_obligation AS target
    USING (SELECT * FROM @req WHERE IsAdopted = 1) AS src
       ON target.practice_instance_id = @practice_instance_id
      AND target.obligation_id        = src.ObligationId
    WHEN MATCHED THEN UPDATE SET
        organization_modified  = src.IsModified,
        execution_frequency_id = src.ExecutionFrequencyId,
        execution_frequency    = COALESCE(src.ExecutionFrequency, src.PubExecutionFrequency),
        assurance_frequency_id = src.AssuranceFrequencyId,
        assurance_frequency    = src.AssuranceFrequency,
        responsibility         = COALESCE(src.Responsibility,    src.PubResponsibility),
        approval_authority     = COALESCE(src.ApprovalAuthority, src.PubApprovalAuthority),
        retention_period       = COALESCE(src.RetentionPeriod,   src.PubRetention),
        assurance_type         = COALESCE(src.AssuranceType, target.assurance_type),
        remarks                = src.Remarks,
        event_type_id          = COALESCE(src.EventTypeId, target.event_type_id),
        sla_value              = COALESCE(src.SlaValue,    target.sla_value),
        sla_unit               = COALESCE(src.SlaUnit,     target.sla_unit),
        implementation_status_id = COALESCE(src.ImplementationStatusId, target.implementation_status_id),
        -- Migration 244: same "absent means keep what's stored" contract
        -- the other overrides use. When the operator switches assurance
        -- to Manual the UI will send NULL for both, which keeps the last
        -- known values; if that becomes wrong later we surface a
        -- "Clear" action that sends an explicit empty string / 0.
        connection_type_id     = COALESCE(src.ConnectionTypeId, target.connection_type_id),
        connection_url         = COALESCE(src.ConnectionUrl,    target.connection_url),
        obligation_name        = src.ObligationName,
        obligation_type_code   = src.ObligationTypeCode,
        release_id             = COALESCE(src.ReleaseId, target.release_id),
        status                 = N'Active',
        record_status_id       = @active_record_status_id,
        updated_by             = @actor,
        updated_dt             = SYSUTCDATETIME()
    WHEN NOT MATCHED THEN INSERT
        (organization_id, practice_instance_id, obligation_id, release_id,
         obligation_name, obligation_type_code,
         inherited_from_repository, organization_modified,
         execution_frequency_id, execution_frequency,
         assurance_frequency_id, assurance_frequency,
         responsibility, approval_authority, retention_period, assurance_type, remarks,
         event_type_id, sla_value, sla_unit, implementation_status_id,
         connection_type_id, connection_url,
         adopted_by, adopted_dt, status, record_status_id, entered_by)
    VALUES
        (@organization_id, @practice_instance_id, src.ObligationId, src.ReleaseId,
         src.ObligationName, src.ObligationTypeCode,
         1, src.IsModified,
         src.ExecutionFrequencyId, COALESCE(src.ExecutionFrequency, src.PubExecutionFrequency),
         src.AssuranceFrequencyId, src.AssuranceFrequency,
         COALESCE(src.Responsibility,    src.PubResponsibility),
         COALESCE(src.ApprovalAuthority, src.PubApprovalAuthority),
         COALESCE(src.RetentionPeriod,   src.PubRetention),
         src.AssuranceType,
         src.Remarks,
         src.EventTypeId, src.SlaValue, src.SlaUnit, src.ImplementationStatusId,
         src.ConnectionTypeId, src.ConnectionUrl,
         @actor, SYSUTCDATETIME(), N'Active', @active_record_status_id, @actor);

    UPDATE pio
       SET status     = N'Retired',
           updated_by = @actor,
           updated_dt = SYSUTCDATETIME()
    FROM  grac_practice.practice_instance_obligation pio
    JOIN  @req r ON r.ObligationId = pio.obligation_id
    WHERE pio.practice_instance_id = @practice_instance_id
      AND r.IsAdopted = 0
      AND pio.status = N'Active';

    UPDATE pie
       SET status     = N'Retired',
           updated_by = @actor,
           updated_dt = SYSUTCDATETIME()
    FROM  grac_practice.practice_instance_evidence pie
    JOIN  @req r ON r.ObligationId = pie.source_obligation_id
    WHERE pie.practice_instance_id = @practice_instance_id
      AND r.IsAdopted = 0
      AND pie.status = N'Active'
      AND pie.organization_modified = 0
      AND NULLIF(LTRIM(RTRIM(ISNULL(pie.evidence_location, N''))), N'') IS NULL
      AND NULLIF(LTRIM(RTRIM(ISNULL(pie.evidence_locator,  N''))), N'') IS NULL
      AND NULLIF(LTRIM(RTRIM(ISNULL(pie.evidence_owner,    N''))), N'') IS NULL;

    -- evidence: extracted to
    -- grac_practice.sp_resolve_evidence_reconcile_for_instance by migration
    -- 304, and called here rather than held twice. The procedure drives off
    -- the adoption TABLE, which this procedure has already written above, so
    -- the set it sees is what @req just made true -- plus any obligation
    -- adopted on an earlier call whose evidence was never created.
    --
    -- It returns no result set, so a plain EXEC is safe inside this
    -- transaction: nothing reaches the caller and nothing blocks the
    -- ROLLBACK that XACT_ABORT may need.
    EXEC grac_practice.sp_resolve_evidence_reconcile_for_instance
         @practice_instance_id = @practice_instance_id,
         @actor                = @actor;

    COMMIT TRAN;

    SELECT r.ObligationId   AS ObligationId,
           r.ObligationName AS ObligationName,
           CASE WHEN r.IsAdopted = 1 THEN N'Adopted' ELSE N'Removed' END AS Outcome,
           r.IsModified     AS OrganizationModified,
           CASE WHEN r.IsAdopted = 1 AND r.ReleaseId IS NULL THEN CAST(1 AS BIT)
                ELSE CAST(0 AS BIT) END AS NotSubscribed,
           (SELECT COUNT(*) FROM grac_practice.practice_instance_evidence pie
             WHERE pie.practice_instance_id = @practice_instance_id
               AND pie.source_obligation_id = r.ObligationId
               AND pie.status = N'Active') AS EvidenceRows,
           (SELECT COUNT(DISTINCT oe.evidence_type_id)
              FROM grac_practice.vw_pm_obligation_evidence oe
              JOIN GRAC_New.evidence_type_master get ON get.evidence_type_id = oe.evidence_type_id
             WHERE oe.organization_id = @organization_id
               AND oe.obligation_id = r.ObligationId
               AND NOT EXISTS (SELECT 1 FROM grac_practice.evidence_type_master pet
                                WHERE pet.evidence_type_name = get.evidence_type_name
                                  AND pet.is_active = 1)) AS UnmappedEvidenceTypes
    FROM   @req r
    ORDER  BY r.ObligationName;
END
GO

-- ---------------------------------------------------------------------
-- sp_resolve_evidence_list (from 306)
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE grac_practice.sp_resolve_evidence_list
    @practice_instance_id BIGINT,
    @obligation_id        BIGINT = NULL,
    -- 232. Filters to one organisation-defined obligation. Separate from
    -- @obligation_id rather than overloading it: they index different
    -- tables, and a NULL @obligation_id already means "every row".
    @practice_instance_obligation_id BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @practice_instance_id IS NULL
        THROW 52640, 'sp_resolve_evidence_list: practice_instance_id is required.', 1;

    -- 394: repository evidence text comes from the organization's copy.
    DECLARE @copy_organization_id BIGINT = (
        SELECT organization_id FROM grac_practice.practice_instance
        WHERE practice_instance_id = @practice_instance_id);

    SELECT
        e.evidence_id             AS EvidenceId,
        e.source_obligation_id    AS SourceObligationId,
        -- 231/232. A locally added obligation has no GRAC_New id, so this
        -- is what says which one an evidence row belongs to.
        e.source_practice_instance_obligation_id AS SourcePracticeInstanceObligationId,
        -- Migration 254: the organisation's own label for this row.
        e.evidence_name           AS EvidenceName,
        e.evidence_type_id        AS EvidenceTypeId,
        et.evidence_type_name     AS EvidenceType,

        -- Migration 306: what the authority published as the instruction
        -- for this evidence. Exact source row first, then the
        -- obligation + type fallback for a row that has no
        -- source_obligation_evidence_id.
        -- CAST before LTRIM/RTRIM: the column is repository-owned, and
        -- LTRIM on an ntext argument is Msg 8116, not a NULL. Casting
        -- costs nothing when it is already NVARCHAR(MAX) and removes the
        -- guess about which it is.
        COALESCE(
            (SELECT TOP 1 NULLIF(LTRIM(RTRIM(CAST(roe.remarks AS NVARCHAR(MAX)))), N'')
             FROM   grac_practice.fn_org_requirement_obligation_evidence(@copy_organization_id) roe
             WHERE  roe.obligation_evidence_id = e.source_obligation_evidence_id
               AND  roe.status = N'Active'),
            (SELECT TOP 1 NULLIF(LTRIM(RTRIM(CAST(roe2.remarks AS NVARCHAR(MAX)))), N'')
             FROM   grac_practice.vw_pm_obligation_evidence oe
             JOIN   grac_practice.fn_org_requirement_obligation_evidence(@copy_organization_id) roe2
                    ON roe2.obligation_evidence_id = oe.obligation_evidence_id
             JOIN   GRAC_New.evidence_type_master get
                    ON get.evidence_type_id = oe.evidence_type_id
             JOIN   grac_practice.evidence_type_master pet
                    ON pet.evidence_type_name = get.evidence_type_name
                   AND pet.is_active = 1
             WHERE  oe.organization_id    = @copy_organization_id
               AND  oe.obligation_id      = e.source_obligation_id
               AND  pet.evidence_type_id  = e.evidence_type_id
               AND  roe2.status = N'Active'
               AND  NULLIF(LTRIM(RTRIM(CAST(roe2.remarks AS NVARCHAR(MAX)))), N'') IS NOT NULL
             ORDER  BY oe.obligation_evidence_id)
        )                         AS EvidenceRemarks,

        e.is_mandatory            AS IsMandatory,
        e.collection_method_id    AS CollectionMethodId,
        cm.collection_method_name AS CollectionMethod,
        e.collection_frequency_id AS CollectionFrequencyId,
        f.frequency_name          AS CollectionFrequency,
        e.assurance_type_id       AS AssuranceTypeId,
        at2.assurance_type_name   AS AssuranceType,
        e.retention_period        AS RetentionPeriod,
        e.evidence_owner          AS EvidenceOwner,
        e.evidence_description    AS EvidenceDescription,
        e.evidence_location       AS EvidenceLocation,
        e.evidence_locator        AS EvidenceLocator,
        e.alignment_status_id     AS AlignmentStatusId,
        al.alignment_status_name  AS AlignmentStatus,
        e.inherited_from_repository AS InheritedFromRepository,
        e.organization_modified     AS OrganizationModified,

        -- The same two-field test assurance eligibility applies, so the
        -- workspace cannot report ready on a row assurance would reject.
        -- Migration 254 deliberately does NOT add the name here, and 306
        -- does not add the remark: a published instruction is not an
        -- organisation answer, so it cannot move a row towards resolved.
        CAST(CASE WHEN NULLIF(LTRIM(RTRIM(ISNULL(e.evidence_location, N''))), N'') IS NOT NULL
                   AND NULLIF(LTRIM(RTRIM(ISNULL(e.evidence_locator,  N''))), N'') IS NOT NULL
                  THEN 1 ELSE 0 END AS BIT) AS IsResolved
    FROM   grac_practice.practice_instance_evidence e
    LEFT   JOIN grac_practice.evidence_type_master et
           ON et.evidence_type_id = e.evidence_type_id
    LEFT   JOIN grac_practice.collection_method_master cm
           ON cm.collection_method_id = e.collection_method_id
    LEFT   JOIN grac_practice.frequency_master f
           ON f.frequency_id = e.collection_frequency_id
    LEFT   JOIN grac_practice.assurance_type_master at2
           ON at2.assurance_type_id = e.assurance_type_id
    LEFT   JOIN grac_practice.evidence_alignment_status_master al
           ON al.alignment_status_id = e.alignment_status_id
    WHERE  e.practice_instance_id = @practice_instance_id
      AND  e.status = N'Active'
      AND (@obligation_id IS NULL OR e.source_obligation_id = @obligation_id)
      AND (@practice_instance_obligation_id IS NULL
           OR e.source_practice_instance_obligation_id = @practice_instance_obligation_id)
    ORDER  BY CASE WHEN e.source_obligation_id IS NULL THEN 1 ELSE 0 END,
              e.source_obligation_id,
              -- Migration 254: a named row sorts by its name, an unnamed
              -- one keeps sorting by type, so adding a name never scatters
              -- the list into a new order the operator did not ask for.
              COALESCE(NULLIF(LTRIM(RTRIM(e.evidence_name)), N''), et.evidence_type_name);
END
GO

-- ---------------------------------------------------------------------
-- sp_resolve_instance_list (from 315)
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE grac_practice.sp_resolve_instance_list
    @organization_id     BIGINT,
    @caller_employee_id  BIGINT       = NULL,
    @is_admin            BIT          = 0,
    @search              NVARCHAR(200) = N'',
    @page_number         INT          = 1,
    @page_size           INT          = 25,
    @include_retired     BIT          = 0,
    @practice_id                 BIGINT = NULL,
    @organization_requirement_id BIGINT = NULL,
    -- NEW in 315. Both NULL = no opinion, so every existing caller
    -- (risk-centre drill-downs, tooling, older API binaries that never
    -- pass them) sees exactly the rows it saw before.
    @owner_employee_id     BIGINT        = NULL,
    @implementation_status NVARCHAR(100) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @organization_id IS NULL
        THROW 52600, 'sp_resolve_instance_list: organization_id is required.', 1;

    -- A non-admin with no employee id would otherwise see everything.
    IF @is_admin = 0 AND @caller_employee_id IS NULL
        THROW 52601, 'sp_resolve_instance_list: caller_employee_id is required for a non-admin caller.', 1;

    IF @page_size IS NULL OR @page_size <= 0 SET @page_size = 25;
    IF @page_size > 200 SET @page_size = 200;
    IF @page_number IS NULL OR @page_number < 1 SET @page_number = 1;
    IF @search IS NULL SET @search = N'';
    IF @include_retired IS NULL SET @include_retired = 0;
    IF @owner_employee_id IS NOT NULL AND @owner_employee_id <= 0 SET @owner_employee_id = NULL;
    IF @implementation_status IS NOT NULL AND LTRIM(RTRIM(@implementation_status)) = N''
        SET @implementation_status = NULL;

    DECLARE @offset INT = (@page_number - 1) * @page_size;

    -- ---- 1. The page of instances -------------------------------
    SELECT
        pi.practice_instance_id      AS PracticeInstanceId,
        pi.instance_code             AS InstanceCode,
        pi.instance_name             AS InstanceName,
        p.practice_id                AS PracticeId,
        p.practice_code              AS PracticeCode,
        p.practice_name              AS PracticeName,
        pi.primary_owner_id          AS OwnerEmployeeId,
        COALESCE(owner_emp.employee_name, pi.primary_owner) AS OwnerName,
        COALESCE(dept.department_name, pi.department)       AS Department,
        pi.criticality               AS Criticality,
        COALESCE(ims.status_name, pi.implementation_status) AS ImplementationStatus,
        pi.status                    AS Status,
        ob.TotalObligations          AS TotalObligations,
        ob.AdoptedObligations        AS AdoptedObligations,
        dep.TotalDependencies        AS TotalDependencies,
        dep.ResolvedDependencies     AS ResolvedDependencies,
        COUNT(*) OVER ()             AS TotalRows
    FROM   grac_practice.practice_instance pi
    JOIN   grac_practice.practice p
           ON p.practice_id = pi.practice_id
    LEFT   JOIN grac_practice.organization_employee owner_emp
           ON owner_emp.employee_id = pi.primary_owner_id
    LEFT   JOIN grac_practice.organization_department dept
           ON dept.department_id = pi.department_id
    LEFT   JOIN grac_practice.implementation_status_master ims
           ON ims.implementation_status_id = pi.implementation_status_id
    OUTER  APPLY (
        SELECT COUNT(*) AS TotalObligations,
               SUM(CASE WHEN a.practice_instance_obligation_id IS NOT NULL THEN 1 ELSE 0 END) AS AdoptedObligations
        FROM (
            SELECT DISTINCT orm.obligation_id
            FROM   grac_practice.practice pp
            JOIN   grac_practice.organization_requirement req
                   ON req.organization_requirement_id = pp.organization_requirement_id
            LEFT   JOIN grac_practice.fn_org_requirement(@organization_id) repo_req
                   ON repo_req.requirement_code = req.requirement_code AND repo_req.status = N'Active'
            JOIN   grac_practice.fn_org_obligation_requirement_release_map(@organization_id) orm
                   ON orm.requirement_id = COALESCE(req.repository_requirement_id, repo_req.requirement_id)
                  AND orm.status = N'Active'
            JOIN   grac_practice.fn_org_requirement_obligation(@organization_id) ro
                   ON ro.obligation_id = orm.obligation_id AND ro.status = N'Active'
            WHERE  pp.practice_id = pi.practice_id
              AND  EXISTS (SELECT 1 FROM grac_practice.repository_subscription s
                            WHERE s.organization_id = pi.organization_id
                              AND s.release_id = orm.release_id
                              AND s.status = N'Active')
        ) o
        LEFT JOIN grac_practice.practice_instance_obligation a
               ON a.practice_instance_id = pi.practice_instance_id
              AND a.obligation_id        = o.obligation_id
              AND a.status               = N'Active'
    ) ob
    OUTER  APPLY (
        SELECT COUNT(DISTINCT d.dependency_type_id) AS TotalDependencies,
               COUNT(DISTINCT r.dependency_type_id) AS ResolvedDependencies
        FROM   grac_practice.practice_instance_dependency d
        LEFT   JOIN grac_practice.practice_dependency_resolution r
               ON r.practice_instance_id = d.practice_instance_id
              AND r.dependency_type_id   = d.dependency_type_id
              AND r.is_active            = 1
        WHERE  d.practice_instance_id = pi.practice_instance_id
          AND  d.status = N'Active'
    ) dep
    WHERE  pi.organization_id = @organization_id
      AND (@include_retired = 1 OR pi.status = N'Active')
      AND (@is_admin = 1 OR pi.primary_owner_id = @caller_employee_id)
      AND (@practice_id IS NULL OR pi.practice_id = @practice_id)
      AND (@organization_requirement_id IS NULL
           OR p.organization_requirement_id = @organization_requirement_id)
      -- NEW in 315. NULL = no opinion.
      AND (@owner_employee_id IS NULL OR pi.primary_owner_id = @owner_employee_id)
      AND (@implementation_status IS NULL
           OR COALESCE(ims.status_name, pi.implementation_status) = @implementation_status)
      AND (@search = N''
           OR pi.instance_code LIKE N'%' + @search + N'%'
           OR pi.instance_name LIKE N'%' + @search + N'%'
           OR p.practice_code  LIKE N'%' + @search + N'%'
           OR p.practice_name  LIKE N'%' + @search + N'%')
    ORDER  BY CASE WHEN pi.status = N'Active' THEN 0 ELSE 1 END,
              pi.instance_code
    OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;

    -- ---- 2. Owner options, in scope -------------------------------
    -- Same scope as the row set, WITHOUT @search / @owner_employee_id /
    -- @implementation_status: the dropdown must offer every owner the
    -- caller could filter to, including one whose only instance sits on
    -- a page not currently loaded.
    SELECT DISTINCT
        pi.primary_owner_id AS OwnerEmployeeId,
        COALESCE(owner_emp.employee_name, pi.primary_owner) AS OwnerName
    FROM   grac_practice.practice_instance pi
    JOIN   grac_practice.practice p
           ON p.practice_id = pi.practice_id
    LEFT   JOIN grac_practice.organization_employee owner_emp
           ON owner_emp.employee_id = pi.primary_owner_id
    WHERE  pi.organization_id = @organization_id
      AND (@include_retired = 1 OR pi.status = N'Active')
      AND (@is_admin = 1 OR pi.primary_owner_id = @caller_employee_id)
      AND (@practice_id IS NULL OR pi.practice_id = @practice_id)
      AND (@organization_requirement_id IS NULL
           OR p.organization_requirement_id = @organization_requirement_id)
      AND pi.primary_owner_id IS NOT NULL
    ORDER BY OwnerName;

    -- ---- 3. Status options, in scope -------------------------------
    -- Free text today (see docs/organization-practices-implementation-
    -- status.md -- pi.implementation_status can hold a legacy value with
    -- no row in implementation_status_master, e.g. the pre-045 default
    -- "Not Started"), so the option list is read off the data rather
    -- than off the master table -- a fixed master list would silently
    -- omit any value the master does not carry.
    SELECT DISTINCT
        COALESCE(ims.status_name, pi.implementation_status) AS ImplementationStatus
    FROM   grac_practice.practice_instance pi
    JOIN   grac_practice.practice p
           ON p.practice_id = pi.practice_id
    LEFT   JOIN grac_practice.implementation_status_master ims
           ON ims.implementation_status_id = pi.implementation_status_id
    WHERE  pi.organization_id = @organization_id
      AND (@include_retired = 1 OR pi.status = N'Active')
      AND (@is_admin = 1 OR pi.primary_owner_id = @caller_employee_id)
      AND (@practice_id IS NULL OR pi.practice_id = @practice_id)
      AND (@organization_requirement_id IS NULL
           OR p.organization_requirement_id = @organization_requirement_id)
      AND COALESCE(ims.status_name, pi.implementation_status) IS NOT NULL
    ORDER BY ImplementationStatus;
END
GO

-- ---------------------------------------------------------------------
-- sp_resolve_obligation_list (from 353)
-- ---------------------------------------------------------------------
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
        ev.ResolvedEvidenceCount        AS ResolvedEvidenceCount
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
            AND NULLIF(LTRIM(RTRIM(ISNULL(pie2.evidence_locator,  N''))), N'') IS NOT NULL)  AS ResolvedEvidenceCount
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

-- =====================================================================
-- Verification
-- =====================================================================
-- (a) Expect 0 rows: a re-issued object still joining a grac_new
--     obligation-catalogue table or the unscoped typed-detail view.
SELECT v.object_name AS ObjectName
FROM (VALUES ('grac_practice.vw_pm_obligation_evidence'),
             ('grac_practice.vw_pm_practice_default_frequency'),
             ('grac_practice.vw_pm_event_driven_obligation'),
             ('grac_practice.vw_pm_instance_effective_assurance_frequency'),
             ('grac_practice.vw_pm_instance_schedulable_obligations'),
             ('dbo.sp_pm_view_obligations_typed'),
             ('grac_practice.sp_resolve_evidence_reconcile_for_instance'),
             ('grac_practice.sp_resolve_obligation_adopt'),
             ('grac_practice.sp_resolve_evidence_list'),
             ('grac_practice.sp_resolve_instance_list'),
             ('grac_practice.sp_resolve_obligation_list')) AS v(object_name)
WHERE OBJECT_ID(v.object_name) IS NULL
   OR OBJECT_DEFINITION(OBJECT_ID(v.object_name)) LIKE '%JOIN grac_new.requirement %'
   OR OBJECT_DEFINITION(OBJECT_ID(v.object_name)) LIKE '%JOIN grac_new.requirement_obligation %'
   OR OBJECT_DEFINITION(OBJECT_ID(v.object_name)) LIKE '%JOIN grac_new.requirement_obligation_evidence%'
   OR OBJECT_DEFINITION(OBJECT_ID(v.object_name)) LIKE '%FROM grac_new.requirement_obligation_evidence%'
   OR OBJECT_DEFINITION(OBJECT_ID(v.object_name)) LIKE '%grac_new.obligation_requirement_release_map%'
   OR OBJECT_DEFINITION(OBJECT_ID(v.object_name)) LIKE '%JOIN grac_new.obligation_assurance_spec%'
   OR OBJECT_DEFINITION(OBJECT_ID(v.object_name)) LIKE '%JOIN grac_practice.vw_pm_obligation_typed_detail%'
   OR OBJECT_DEFINITION(OBJECT_ID(v.object_name)) LIKE '%FROM grac_practice.vw_pm_obligation_typed_detail%';

-- (b) Expect 0 rows anywhere else: any other procedure / view / function
--     that still reads the unscoped typed-detail view (only the 391 copy
--     source may).
SELECT OBJECT_SCHEMA_NAME(m.object_id) + N'.' + OBJECT_NAME(m.object_id) AS StillReadsUnscopedTypedDetail
FROM   sys.sql_modules m
WHERE  m.definition LIKE '%vw_pm_obligation_typed_detail td%'
  AND  OBJECT_NAME(m.object_id) NOT IN (N'vw_repo_src_obligation', N'vw_pm_org_obligation_typed_detail');

-- (c) Row counts: typed detail and evidence per organization.
SELECT td.OrganizationId, COUNT(*) AS Obligations,
       (SELECT COUNT(*) FROM grac_practice.vw_pm_obligation_evidence e
         WHERE e.organization_id = td.OrganizationId) AS EvidenceRows
FROM   grac_practice.vw_pm_org_obligation_typed_detail td
GROUP  BY td.OrganizationId
ORDER  BY td.OrganizationId;
GO

PRINT '394 complete.';
GO
