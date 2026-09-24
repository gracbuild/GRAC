-- =====================================================================
-- 342 vw_pm_event_driven_obligation -- custom obligations join the view
--
-- WHAT AND WHY
-- ------------
-- vw_pm_event_driven_obligation (127) is the join the entire Configure-
-- Checklists screen is built on -- sp_event_obligation_mapping_list,
-- sp_event_obligation_applicability_save's existence check,
-- sp_event_obligation_coverage_list and sp_event_obligation_raise (all
-- 128/131, re-issued with a PROFILE branch by 331) all read it, none of
-- them read the base tables directly. It has sourced obligations
-- exclusively from GRAC_New.requirement_obligation since 127 -- there was
-- nothing else to source, because an organisation-authored obligation had
-- no way to declare itself event-driven until 340, and nowhere to record
-- an applicability decision until 341. Both now exist. This migration is
-- what actually makes a custom obligation visible to the rest of the
-- chain: everything downstream reads this view, so extending it here is
-- the one change every reader benefits from at once.
--
-- TWO NEW BRANCHES, ONE PER LOCAL IDENTITY KIND
-- ------------------------------------------------
-- Branch 2: practice_obligation (307) rows with event_type_id set (340).
--   One row per practice-level definition -- NOT one per fanned-out copy.
--   A catalog obligation's applicability decision already covers every
--   instance of the practice without multiplying per instance; a
--   practice-level custom obligation gets the identical treatment, which
--   is the whole reason 341's identity choice was practice_obligation_id
--   and not a copy's own id (see 341's header, "confirmed with sir").
--
-- Branch 3: practice_instance_obligation (227) rows that are BOTH
--   uncataloged (obligation_id IS NULL) AND NOT a practice-level copy
--   (source_practice_obligation_id IS NULL) -- 307's own "instance custom"
--   kind. A fanned-out COPY of a practice-level definition
--   (source_practice_obligation_id IS NOT NULL) is deliberately excluded
--   from this branch: it is the same obligation branch 2 already lists
--   once, and listing it again per instance would both duplicate the
--   Checklists tab row and let two different applicability decisions
--   apply to what should be one.
--
-- COLUMNS THAT DO NOT APPLY TO A CUSTOM ROW
-- --------------------------------------------
-- organization_requirement_id, requirement_code, requirement_name and
-- RequirementApplicability describe a GRAC_New requirement chain a
-- locally-authored obligation was never subscribed through -- NULL, same
-- as the organisation-defined branch of sp_resolve_obligation_list (244)
-- already does for its own equivalent columns. release_id is NULL for the
-- same reason. PracticeApplicability, by contrast, IS real: both new
-- branches join grac_practice.practice by practice_id and project its own
-- applicability_status, the same column the catalog branch reads --
-- there is a real practice underneath a custom obligation even though
-- there is no requirement.
--
-- is_subscribed is CAST(1 AS BIT) for both -- "subscribed" is a catalog
-- concept (127: whether the org's repository_subscription covers the
-- release that carried the obligation); an organisation-authored
-- obligation was never subscribed to anything, it was authored directly,
-- so there is nothing to be unsubscribed FROM. Reading it as "in scope"
-- (1) is what keeps @include_unsubscribed = 0, the default every caller
-- uses today, from silently hiding every custom obligation.
--
-- trigger_mode is the literal N'EventDriven' rather than a read from
-- GRAC_New.obligation_assurance_spec, which has no row for a custom
-- obligation -- event_type_id IS NOT NULL is already this table's own
-- version of that vocabulary (340's header makes the same point for
-- practice_instance_obligation.event_type_id).
--
-- WHY SOME NULL PLACEHOLDERS ARE NOT EXPLICITLY CAST
-- ------------------------------------------------------
-- This codebase's own convention (244, 230) is CAST(NULL AS <type>) for a
-- branch that has nothing to contribute to a column. Followed here for
-- every column this migration knows the type of. organization_requirement_id,
-- release_id, obligation_id, and the two new local-identity columns are
-- CAST to BIGINT because their type is certain. requirement_code,
-- requirement_name and RequirementApplicability are left as bare NULL /
-- literal N'EventDriven' instead: organization_requirement and practice
-- are base tables from outside the numbered migration set this repository
-- exposes, so their exact declared lengths are not available to write a
-- confident CAST against, and SQL Server resolves an untyped NULL (or an
-- NVARCHAR literal) against the REAL type the catalog branch already
-- supplies for that column -- the union does not need every branch to
-- state a type, only for one of them to.
--
-- WHAT THIS MIGRATION DOES NOT TOUCH
-- ---------------------------------
-- sp_event_obligation_mapping_list, sp_event_obligation_applicability_save,
-- sp_event_obligation_coverage_list and sp_event_obligation_raise all key
-- several operations -- GROUP BY, PARTITION BY, the applicability join --
-- on obligation_id alone, which will be NULL for both new branches. Making
-- those four procedures recognise a row by whichever of the three identity
-- columns it actually carries is 343's work, not this migration's: the
-- view is the one place every one of them reads from, and getting its
-- shape right first is what makes 343 an extension of four call sites
-- rather than a second attempt at getting the view right too. Until 343
-- lands, a custom obligation is visible in vw_pm_event_driven_obligation
-- (inspectable directly, exactly as 127's own header describes the view's
-- purpose) but not yet reachable through the four procedures above.
--
-- SAFE TO RE-RUN. Requires 127, 307, 329, 340, 341.
-- ASCII-only.
--
-- DEPENDS ON: 127 (the view being extended), 307 (practice_obligation),
--             329 (profile_id -- untouched here, carried through only
--             because this is CREATE OR ALTER on the same view, not a
--             rewrite), 340 (event_type_id on both custom-obligation
--             kinds), 341 (local_practice_obligation_id /
--             local_instance_obligation_id -- not used as OUTPUT columns
--             by the view itself, but named identically so 343 can read
--             the view and the table with one column name per kind).
-- Rollback:   database/342_event_driven_obligation_view_local_kinds_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF SCHEMA_ID('grac_practice') IS NULL OR SCHEMA_ID('GRAC_New') IS NULL
BEGIN
    PRINT 'ABORT (342): schema grac_practice or GRAC_New missing.';
    SET NOEXEC ON;
END
GO

IF OBJECT_ID('grac_practice.vw_pm_event_driven_obligation','V') IS NULL
BEGIN
    PRINT 'ABORT (342): vw_pm_event_driven_obligation missing (run 127 first).';
    SET NOEXEC ON;
END
GO

IF OBJECT_ID('grac_practice.practice_obligation','U') IS NULL
BEGIN
    PRINT 'ABORT (342): practice_obligation missing (run 307 first).';
    SET NOEXEC ON;
END
GO

IF COL_LENGTH('grac_practice.practice_obligation','event_type_id') IS NULL
   OR COL_LENGTH('grac_practice.practice_instance_obligation','event_type_id') IS NULL
BEGIN
    PRINT 'ABORT (342): event_type_id missing on practice_obligation or practice_instance_obligation (run 340 first).';
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- vw_pm_event_driven_obligation -- 127's branch 1, unchanged except for
-- the two new trailing columns, plus branches 2 and 3.
-- =====================================================================
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
    LEFT JOIN  GRAC_New.requirement repo_req
           ON  repo_req.requirement_code = req.requirement_code
          AND  repo_req.status           = N'Active'
    JOIN       GRAC_New.obligation_requirement_release_map orm
           ON  orm.requirement_id = COALESCE(req.repository_requirement_id, repo_req.requirement_id)
          AND  orm.status         = N'Active'
    JOIN       GRAC_New.requirement_obligation o
           ON  o.obligation_id = orm.obligation_id
    JOIN       GRAC_New.obligation_assurance_spec spec
           ON  spec.obligation_id = o.obligation_id
          AND  spec.status        = N'Active'
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
PRINT '342: vw_pm_event_driven_obligation sources practice-level and instance-only custom obligations too.';
GO

-- =====================================================================
-- Verification
-- =====================================================================
PRINT '=== 342 verification ===';

SELECT '342-a view compiles' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.vw_pm_event_driven_obligation','V') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '342-b view projects local_practice_obligation_id',
       CASE WHEN EXISTS (SELECT 1 FROM sys.columns
                          WHERE object_id = OBJECT_ID('grac_practice.vw_pm_event_driven_obligation','V')
                            AND name = 'local_practice_obligation_id')
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '342-c view projects local_instance_obligation_id',
       CASE WHEN EXISTS (SELECT 1 FROM sys.columns
                          WHERE object_id = OBJECT_ID('grac_practice.vw_pm_event_driven_obligation','V')
                            AND name = 'local_instance_obligation_id')
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
-- Regression guard: the original catalog branch's row count for organisations
-- that have never authored a custom obligation must be unchanged -- adding
-- branches that return zero rows must not multiply or drop catalog rows.
SELECT '342-d catalog branch alone still matches the pre-342 view',
       CASE WHEN (SELECT COUNT(*) FROM grac_practice.vw_pm_event_driven_obligation
                   WHERE local_practice_obligation_id IS NULL
                     AND local_instance_obligation_id IS NULL)
                 = (SELECT COUNT(*) FROM grac_practice.vw_pm_event_driven_obligation
                     WHERE obligation_id IS NOT NULL)
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '342-e a practice-level custom obligation appears when one exists',
       CASE WHEN NOT EXISTS (
                SELECT 1 FROM grac_practice.practice_obligation
                 WHERE event_type_id IS NOT NULL AND status = N'Active')
            THEN 'SKIP -- no event-driven practice-level custom obligation to check against'
            WHEN EXISTS (SELECT 1 FROM grac_practice.vw_pm_event_driven_obligation
                          WHERE local_practice_obligation_id IS NOT NULL)
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '342-f an instance-only custom obligation appears when one exists',
       CASE WHEN NOT EXISTS (
                SELECT 1 FROM grac_practice.practice_instance_obligation
                 WHERE obligation_id IS NULL AND source_practice_obligation_id IS NULL
                   AND event_type_id IS NOT NULL AND status = N'Active')
            THEN 'SKIP -- no event-driven instance-only custom obligation to check against'
            WHEN EXISTS (SELECT 1 FROM grac_practice.vw_pm_event_driven_obligation
                          WHERE local_instance_obligation_id IS NOT NULL)
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
-- A fanned-out COPY must not appear a second time through branch 3.
SELECT '342-g fanned-out copies are not double-counted',
       CASE WHEN NOT EXISTS (
                SELECT 1 FROM grac_practice.practice_instance_obligation
                 WHERE source_practice_obligation_id IS NOT NULL
                   AND event_type_id IS NOT NULL AND status = N'Active')
            THEN 'SKIP -- no fanned-out event-driven copy to check against'
            WHEN NOT EXISTS (
                SELECT 1 FROM grac_practice.vw_pm_event_driven_obligation v
                 JOIN  grac_practice.practice_instance_obligation pio
                       ON pio.practice_instance_obligation_id = v.local_instance_obligation_id
                 WHERE pio.source_practice_obligation_id IS NOT NULL)
            THEN 'PASS' ELSE 'FAIL -- a copy leaked into branch 3'
            END;

PRINT '';
PRINT '342 complete. The view is directly inspectable now, per 127''s own';
PRINT 'stated purpose:';
PRINT '  SELECT * FROM grac_practice.vw_pm_event_driven_obligation';
PRINT '  WHERE local_practice_obligation_id IS NOT NULL';
PRINT '     OR local_instance_obligation_id IS NOT NULL;';
PRINT 'Next: 343 teaches sp_event_obligation_mapping_list,';
PRINT 'sp_event_obligation_applicability_save and sp_event_obligation_raise';
PRINT '(331''s latest bodies) to key off whichever identity column a row';
PRINT 'carries, not obligation_id alone.';
GO

SET NOEXEC OFF;
GO
