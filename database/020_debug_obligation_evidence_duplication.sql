/*
  020_debug_obligation_evidence_duplication.sql
  ─────────────────────────────────────────────────────────────────────
  Three-output diagnostic script for View Obligations duplication.

  Run in GRAC_NewPhase (or your Practice Management database).

  Outputs:
    1. Raw evidence rows per obligation  (baseline truth)
    2. Mapping rows per obligation+requirement  (detect duplicates)
    3. Final View Obligations result with obligation_evidence_id
       → if any obligation_evidence_id appears >1 time, the JOIN is wrong

  Usage:
    Set @practice_id below (or @organization_requirement_id).
    Run and compare Output 1 count vs Output 3 count per obligation.
    They must match exactly.
  ─────────────────────────────────────────────────────────────────────
*/
SET NOCOUNT ON;

-- ══════════════════════════════════════════════════════════════════════
-- CONFIG: Set ONE of these
-- ══════════════════════════════════════════════════════════════════════
DECLARE @organization_requirement_id BIGINT = NULL;
DECLARE @practice_id                 BIGINT = NULL;
DECLARE @practice_instance_id        BIGINT = NULL;
DECLARE @organization_id             BIGINT = NULL;  -- optional org filter

-- ══════════════════════════════════════════════════════════════════════
-- Cleanup from previous run
-- ══════════════════════════════════════════════════════════════════════
DROP TABLE IF EXISTS #ctx_reqs;
DROP TABLE IF EXISTS #obligations;

-- ══════════════════════════════════════════════════════════════════════
-- Resolve context → requirement_ids
-- ══════════════════════════════════════════════════════════════════════
;WITH context_requirement AS (
    SELECT DISTINCT
        req.organization_requirement_id,
        req.organization_id,
        COALESCE(req.repository_requirement_id, repo_req.requirement_id) repository_requirement_id
    FROM grac_practice.organization_requirement req
    LEFT JOIN GRAC_New.requirement repo_req
      ON repo_req.requirement_code = req.requirement_code AND repo_req.status = 'Active'
    WHERE (@organization_requirement_id IS NOT NULL AND req.organization_requirement_id = @organization_requirement_id)
       OR (@practice_id IS NOT NULL AND EXISTS(
            SELECT 1 FROM grac_practice.practice p
            WHERE p.practice_id = @practice_id AND p.organization_requirement_id = req.organization_requirement_id))
       OR (@practice_instance_id IS NOT NULL AND EXISTS(
            SELECT 1 FROM grac_practice.practice_instance pi
            JOIN grac_practice.practice p ON p.practice_id = pi.practice_id
            WHERE pi.practice_instance_id = @practice_instance_id AND p.organization_requirement_id = req.organization_requirement_id))
),
distinct_requirements AS (
    SELECT DISTINCT repository_requirement_id, organization_id
    FROM context_requirement
    WHERE repository_requirement_id IS NOT NULL
)
SELECT * INTO #ctx_reqs FROM distinct_requirements;

-- Step 1: distinct obligations for this practice/requirement
SELECT DISTINCT orm.obligation_id
INTO #obligations
FROM #ctx_reqs dr
JOIN GRAC_New.obligation_requirement_release_map orm
  ON orm.requirement_id = dr.repository_requirement_id AND orm.status = 'Active'
WHERE (@organization_id IS NULL OR dr.organization_id = @organization_id);

-- Show resolved context
PRINT '=== Context: requirement_ids resolved ===';
SELECT * FROM #ctx_reqs;

PRINT '=== Distinct obligation_ids for this practice ===';
SELECT * FROM #obligations;

-- ══════════════════════════════════════════════════════════════════════
-- OUTPUT 1: Raw evidence table count per obligation
-- This is the TRUTH. UI row count must match this exactly.
-- ══════════════════════════════════════════════════════════════════════
PRINT '';
PRINT '╔══════════════════════════════════════════════════════════════╗';
PRINT '║  OUTPUT 1: Raw evidence rows (requirement_obligation_evidence) ║';
PRINT '╚══════════════════════════════════════════════════════════════╝';

SELECT
    roe.obligation_id,
    roe.obligation_evidence_id,
    roe.evidence_type_id,
    et.evidence_type_name,
    roe.frequency_id         AS assurance_frequency_id,
    roe.retention_requirement,
    roe.remarks,
    roe.status
FROM #obligations dob
JOIN GRAC_New.requirement_obligation_evidence roe
  ON roe.obligation_id = dob.obligation_id AND roe.status = 'Active'
JOIN GRAC_New.evidence_type_master et ON et.evidence_type_id = roe.evidence_type_id
ORDER BY roe.obligation_id, et.display_order, et.evidence_type_name;

PRINT '';
PRINT '--- Evidence count per obligation (this is the expected UI count) ---';
SELECT
    roe.obligation_id,
    COUNT(*) AS evidence_row_count
FROM #obligations dob
JOIN GRAC_New.requirement_obligation_evidence roe
  ON roe.obligation_id = dob.obligation_id AND roe.status = 'Active'
GROUP BY roe.obligation_id;

-- ══════════════════════════════════════════════════════════════════════
-- OUTPUT 2: Mapping table — check for duplicate mappings
-- Same obligation mapped multiple times to same requirement+release = data issue
-- ══════════════════════════════════════════════════════════════════════
PRINT '';
PRINT '╔══════════════════════════════════════════════════════════════╗';
PRINT '║  OUTPUT 2: Mapping table (obligation_requirement_release_map) ║';
PRINT '╚══════════════════════════════════════════════════════════════╝';

SELECT
    orm.requirement_id,
    orm.obligation_id,
    orm.release_id,
    orm.status
FROM #ctx_reqs dr
JOIN GRAC_New.obligation_requirement_release_map orm
  ON orm.requirement_id = dr.repository_requirement_id AND orm.status = 'Active'
WHERE (@organization_id IS NULL OR dr.organization_id = @organization_id)
ORDER BY orm.requirement_id, orm.obligation_id, orm.release_id;

PRINT '';
PRINT '--- Mapping count per obligation (>1 release = old query duplicated evidence) ---';
SELECT
    orm.obligation_id,
    COUNT(DISTINCT orm.release_id) AS release_count,
    COUNT(*) AS total_mapping_rows,
    CASE WHEN COUNT(DISTINCT orm.release_id) > 1
         THEN '*** MULTIPLE RELEASES — old CROSS JOIN query would duplicate evidence ***'
         ELSE 'OK — single release'
    END AS diagnosis
FROM #ctx_reqs dr
JOIN GRAC_New.obligation_requirement_release_map orm
  ON orm.requirement_id = dr.repository_requirement_id AND orm.status = 'Active'
WHERE (@organization_id IS NULL OR dr.organization_id = @organization_id)
GROUP BY orm.obligation_id;

-- ══════════════════════════════════════════════════════════════════════
-- OUTPUT 3: Final View Obligations result (new two-step query)
-- obligation_evidence_id MUST appear exactly once.
-- ══════════════════════════════════════════════════════════════════════
PRINT '';
PRINT '╔══════════════════════════════════════════════════════════════╗';
PRINT '║  OUTPUT 3: Final View Obligations result (fixed query)        ║';
PRINT '╚══════════════════════════════════════════════════════════════╝';

SELECT
    rel.release_id            AS FrameworkReleaseId,
    rel.FrameworkRelease,
    o.obligation_id           AS ObligationId,
    COALESCE(NULLIF(LTRIM(RTRIM(o.obligation_name)), N''), LEFT(o.obligation_text, 300)) AS ObligationName,
    roe.obligation_evidence_id AS EvidenceId,
    roe.evidence_type_id      AS EvidenceTypeId,
    et.evidence_type_name     AS EvidenceType,
    COALESCE(f.frequency_name, cm_freq.option_label) AS Frequency,
    roe.retention_requirement AS RetentionRequirement,
    roe.remarks               AS Remarks
FROM #obligations dob
JOIN GRAC_New.requirement_obligation o
  ON o.obligation_id = dob.obligation_id AND o.status = 'Active'
JOIN GRAC_New.requirement_obligation_evidence roe
  ON roe.obligation_id = o.obligation_id AND roe.status = 'Active'
JOIN GRAC_New.evidence_type_master et ON et.evidence_type_id = roe.evidence_type_id
LEFT JOIN GRAC_New.reference_option cm_freq ON cm_freq.reference_option_id = roe.frequency_id
OUTER APPLY (
    SELECT TOP 1 f2.frequency_id, f2.frequency_name
    FROM grac_practice.frequency_master f2
    WHERE f2.frequency_code = cm_freq.option_value OR f2.frequency_name = cm_freq.option_label
) f
OUTER APPLY (
    SELECT TOP 1 r.release_id,
      COALESCE(a.artifact_code + N' ' + r.version_no, a.artifact_name + N' ' + r.version_no, r.version_no) FrameworkRelease
    FROM #ctx_reqs dr2
    JOIN GRAC_New.obligation_requirement_release_map orm2
      ON orm2.requirement_id = dr2.repository_requirement_id AND orm2.obligation_id = dob.obligation_id AND orm2.status = 'Active'
    JOIN GRAC_New.release r ON r.release_id = orm2.release_id
    LEFT JOIN GRAC_New.artifact a ON a.artifact_id = r.artifact_id
    WHERE (@organization_id IS NULL OR dr2.organization_id = @organization_id)
) rel
ORDER BY rel.FrameworkRelease, et.display_order, et.evidence_type_name;

-- ══════════════════════════════════════════════════════════════════════
-- VALIDATION: Check for duplicates in final result
-- ══════════════════════════════════════════════════════════════════════
PRINT '';
PRINT '╔══════════════════════════════════════════════════════════════╗';
PRINT '║  VALIDATION: Duplicate check on obligation_evidence_id       ║';
PRINT '╚══════════════════════════════════════════════════════════════╝';

SELECT
    roe.obligation_evidence_id,
    COUNT(*) AS occurrences,
    CASE WHEN COUNT(*) > 1
         THEN '*** DUPLICATE — JOIN IS STILL WRONG ***'
         ELSE 'OK'
    END AS status
FROM #obligations dob
JOIN GRAC_New.requirement_obligation o
  ON o.obligation_id = dob.obligation_id AND o.status = 'Active'
JOIN GRAC_New.requirement_obligation_evidence roe
  ON roe.obligation_id = o.obligation_id AND roe.status = 'Active'
GROUP BY roe.obligation_evidence_id
HAVING COUNT(*) > 1;

-- If no rows returned above, all evidence IDs are unique → correct.
PRINT '';
IF NOT EXISTS (
    SELECT 1
    FROM #obligations dob
    JOIN GRAC_New.requirement_obligation o
      ON o.obligation_id = dob.obligation_id AND o.status = 'Active'
    JOIN GRAC_New.requirement_obligation_evidence roe
      ON roe.obligation_id = o.obligation_id AND roe.status = 'Active'
    GROUP BY roe.obligation_evidence_id
    HAVING COUNT(*) > 1
)
    PRINT '✓ PASS: Every obligation_evidence_id appears exactly once. No duplicates.';
ELSE
    PRINT '✗ FAIL: Duplicate obligation_evidence_id found. Check VALIDATION output above.';

-- ══════════════════════════════════════════════════════════════════════
-- CROSS-CHECK: Output 1 count vs Output 3 count per obligation
-- ══════════════════════════════════════════════════════════════════════
PRINT '';
PRINT '╔══════════════════════════════════════════════════════════════╗';
PRINT '║  CROSS-CHECK: Raw count vs Final count per obligation        ║';
PRINT '╚══════════════════════════════════════════════════════════════╝';

SELECT
    raw_ct.obligation_id,
    raw_ct.raw_evidence_count,
    ISNULL(final_ct.final_query_count, 0) AS final_query_count,
    CASE WHEN raw_ct.raw_evidence_count = ISNULL(final_ct.final_query_count, 0)
         THEN 'MATCH'
         ELSE '*** MISMATCH ***'
    END AS result
FROM (
    SELECT roe.obligation_id, COUNT(*) raw_evidence_count
    FROM #obligations dob
    JOIN GRAC_New.requirement_obligation_evidence roe
      ON roe.obligation_id = dob.obligation_id AND roe.status = 'Active'
    GROUP BY roe.obligation_id
) raw_ct
LEFT JOIN (
    SELECT o.obligation_id, COUNT(*) final_query_count
    FROM #obligations dob
    JOIN GRAC_New.requirement_obligation o
      ON o.obligation_id = dob.obligation_id AND o.status = 'Active'
    JOIN GRAC_New.requirement_obligation_evidence roe
      ON roe.obligation_id = o.obligation_id AND roe.status = 'Active'
    GROUP BY o.obligation_id
) final_ct ON final_ct.obligation_id = raw_ct.obligation_id;

-- Cleanup
DROP TABLE IF EXISTS #ctx_reqs;
DROP TABLE IF EXISTS #obligations;

PRINT '';
PRINT 'Done. If all rows show MATCH and PASS, the query is correct.';
