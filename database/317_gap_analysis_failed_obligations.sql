-- =====================================================================
-- 317 Gap Analysis: show the failed Obligation(s) behind an
--                    automatically generated (Implementation) gap
--
-- WHAT AND WHY
-- ------------
-- Sir's request: on the Gap Centre -> Analysis tab, an automatically
-- generated gap (one materialized from a Practice Instance whose
-- Obligation implementation status went Not Implemented / Partially
-- Implemented) should also show WHICH Obligation(s) caused it. A
-- manually created gap (Assurance / Custom / Exception / Risk / Audit
-- source, or a hand-entered Custom gap) must never be associated with
-- an Obligation it has nothing to do with.
--
-- NO NEW RELATIONSHIP. The link this asks for already exists, twice
-- over:
--   * grac_practice.practice_gap_obligation (migration 245) already
--     snapshots exactly which Obligation(s) put a practice_instance's
--     gap in gap territory, and is kept in sync on every obligation
--     save by sp_practice_gap_sync_for_instance. This migration reads
--     it; it does not add to it.
--   * grac_practice.custom_gap already knows which Practice Instance it
--     was materialized from -- source_reference_type = N'PracticeInstance',
--     source_reference_id = the practice_instance_id -- set once by
--     sp_custom_gap_materialize_for_instance (migration 160) and never
--     changed after. That is the SAME key sp_gap_centre_list's dedupe
--     (255) and the materialize proc's own idempotency check (160) both
--     already use for "which instance did this gap come from" -- reused
--     here rather than defining a second notion of it.
--
-- So the join is: custom_gap.source_reference_id (a practice_instance_id)
-- -> practice_gap.practice_instance_id -> practice_gap_obligation
-- (status = 'Active'). A gap that is not gap_source_module_code =
-- 'Implementation' with source_reference_type = 'PracticeInstance' joins
-- to nothing and returns zero rows -- it is structurally impossible for
-- a manually created gap to pick up an Obligation this way.
--
-- WHAT THIS DOES
-- --------------
-- Re-emits sp_custom_gap_linked_artefacts (created by 174; the proc
-- already backing GET /api/practice/gap-lifecycle/gaps/{id}/linked-
-- artefacts, which the Analysis tab already calls on every load and
-- after every analysis save). Task / Exception / Risk result sets are
-- UNCHANGED. A fourth result set, FailedObligations, is added: zero or
-- more rows, one per Obligation snapshot still Active on the gap's
-- practice_gap row, worst status first (same ordering
-- sp_task_center_gaps_list's GapObligationsJson already uses, so the
-- two screens cannot disagree about which Obligation is worse).
--
-- "Without creating duplicate gaps unnecessarily" (sir's requirement) is
-- already true and untouched by this migration: practice_gap carries a
-- UNIQUE constraint on practice_instance_id (245), so multiple failed
-- Obligations on one instance have always produced ONE gap with several
-- practice_gap_obligation children -- never one gap per Obligation. This
-- migration only makes those children visible on the Analysis tab; it
-- does not change how many gaps get created.
--
-- SAFE TO RE-RUN. Requires 174 (sp_custom_gap_linked_artefacts), 245
-- (practice_gap_obligation), 109/160 (source_reference_* columns +
-- materialize). ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

DECLARE @ok BIT = 1;
IF SCHEMA_ID('grac_practice') IS NULL
BEGIN PRINT 'ABORT (317): schema grac_practice missing.'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.sp_custom_gap_linked_artefacts','P') IS NULL
BEGIN PRINT 'ABORT (317): sp_custom_gap_linked_artefacts missing (run 174 first).'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.practice_gap_obligation','U') IS NULL
BEGIN PRINT 'ABORT (317): practice_gap_obligation missing (run 245 first).'; SET @ok = 0; END
IF COL_LENGTH('grac_practice.custom_gap','source_reference_type') IS NULL
BEGIN PRINT 'ABORT (317): custom_gap.source_reference_type missing (run 109 first).'; SET @ok = 0; END
IF @ok = 0
BEGIN
    RAISERROR('317_gap_analysis_failed_obligations: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- sp_custom_gap_linked_artefacts -- Task / Exception / Risk (unchanged
-- from 174) plus the new FailedObligations result set.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_custom_gap_linked_artefacts
    @custom_gap_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF @custom_gap_id IS NULL
        THROW 55510, 'sp_custom_gap_linked_artefacts: custom_gap_id is required.', 1;

    -- Task
    SELECT TOP 1
        N'Task'                     AS ArtefactType,
        t.task_id                   AS ArtefactId,
        t.subject_title             AS Title,
        s.status_code               AS StatusCode
      FROM grac_practice.practice_task t
      JOIN grac_practice.entity_status_master s ON s.entity_status_id = t.current_status_id
     WHERE t.subject_entity_type = N'CustomGap'
       AND t.subject_entity_id   = @custom_gap_id
     ORDER BY t.task_id DESC;

    -- Exception
    SELECT TOP 1
        N'Exception'                AS ArtefactType,
        e.exception_request_id      AS ArtefactId,
        e.request_title             AS Title,
        e.status_code               AS StatusCode
      FROM grac_practice.exception_request e
     WHERE e.custom_gap_id = @custom_gap_id
     ORDER BY e.exception_request_id DESC;

    -- Risk
    SELECT TOP 1
        N'RiskCandidate'            AS ArtefactType,
        r.risk_candidate_id         AS ArtefactId,
        r.candidate_title           AS Title,
        r.status_code               AS StatusCode
      FROM grac_practice.risk_candidate r
     WHERE r.custom_gap_id = @custom_gap_id
     ORDER BY r.risk_candidate_id DESC;

    -- Failed Obligation(s) -- migration 317. Only for a gap that IS an
    -- Implementation gap materialized from a Practice Instance; every
    -- other gap (manual Custom, Assurance, Exception, Risk, Audit, or an
    -- Implementation gap somehow missing its source reference) joins to
    -- nothing here and returns zero rows, so it can never be shown
    -- against an Obligation it was not actually caused by.
    SELECT pgo.practice_instance_obligation_id AS ObligationId,
           pgo.obligation_name                 AS ObligationName,
           pgo.obligation_type_code            AS ObligationTypeCode,
           pgo.logged_status_code              AS LoggedStatusCode,
           pgo.added_dt                        AS AddedDt
      FROM grac_practice.custom_gap cg
      JOIN grac_practice.practice_gap pg
           ON pg.practice_instance_id = cg.source_reference_id
      JOIN grac_practice.practice_gap_obligation pgo
           ON pgo.practice_gap_id = pg.practice_gap_id
          AND pgo.status         = N'Active'
     WHERE cg.custom_gap_id          = @custom_gap_id
       AND cg.gap_source_module_code = N'Implementation'
       AND cg.source_reference_type  = N'PracticeInstance'
       AND cg.source_reference_id   IS NOT NULL
     ORDER BY CASE pgo.logged_status_code
                   WHEN N'Not Implemented'       THEN 1
                   WHEN N'Partially Implemented' THEN 2
                   ELSE 3 END,
              pgo.obligation_name;
END
GO
PRINT '317: sp_custom_gap_linked_artefacts now also returns FailedObligations.';
GO

-- =====================================================================
-- Verification
-- =====================================================================
PRINT '=== 317 verification ===';

DECLARE @def NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_custom_gap_linked_artefacts','P'));

SELECT '317-a proc still present' AS Check_,
       CASE WHEN @def IS NOT NULL THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '317-b Task/Exception/Risk arms untouched',
       CASE WHEN @def LIKE '%practice_task%' AND @def LIKE '%exception_request%'
             AND @def LIKE '%risk_candidate%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '317-c FailedObligations result set added',
       CASE WHEN @def LIKE '%FailedObligations%' OR @def LIKE '%ObligationId%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '317-d guarded to Implementation + PracticeInstance source only',
       CASE WHEN @def LIKE '%gap_source_module_code = N''Implementation''%'
             AND @def LIKE '%source_reference_type  = N''PracticeInstance''%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '317-e reads practice_gap_obligation, not a new table',
       CASE WHEN @def LIKE '%practice_gap_obligation%'
            THEN 'PASS' ELSE 'FAIL' END;

PRINT '';
PRINT '--- Spot check: gaps with FailedObligations rows vs. Implementation gaps ---';
PRINT 'A materialized Implementation gap with an Active practice_gap_obligation';
PRINT 'child should show at least one row here; a manual gap should show none.';

SELECT TOP 20
    cg.custom_gap_id, cg.title, cg.gap_source_module_code,
    cg.source_reference_type, cg.source_reference_id,
    (SELECT COUNT(*)
       FROM grac_practice.practice_gap pg
       JOIN grac_practice.practice_gap_obligation pgo
            ON pgo.practice_gap_id = pg.practice_gap_id AND pgo.status = N'Active'
      WHERE pg.practice_instance_id = cg.source_reference_id) AS FailedObligationCount
FROM grac_practice.custom_gap cg
ORDER BY cg.custom_gap_id DESC;

PRINT '';
PRINT '317 complete. Gap Centre Analysis can now show the failed Obligation(s)';
PRINT 'behind an automatically generated Implementation gap.';
GO

SET NOEXEC OFF;
GO
