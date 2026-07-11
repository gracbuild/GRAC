/*
  019_test_view_obligations.sql
  ─────────────────────────────────────────────────────────────────────
  Standalone test script for Practice Management → View Obligations.
  Run in GRAC_NewPhase to verify the query returns data.

  Usage:
    1. Set ONE of the three context variables below.
    2. Run the script.
    3. Check each numbered section for data.
    4. If Section 05 is empty, check Sections 01-04 to find where the
       chain breaks.

  Tables used (current model):
    GRAC_New.obligation_requirement_release_map   (mapping)
    GRAC_New.requirement_obligation               (obligation master)
    GRAC_New.requirement_obligation_evidence       (evidence per obligation)
  ─────────────────────────────────────────────────────────────────────
*/
SET NOCOUNT ON;

-- ══════════════════════════════════════════════════════════════════════
-- STEP 0: Set your context.  Fill in ONE of these from your Practice row.
-- ══════════════════════════════════════════════════════════════════════
DECLARE @organization_requirement_id BIGINT = NULL;  -- from Organization Requirements grid → Id
DECLARE @practice_id                 BIGINT = NULL;  -- from Practices grid → PracticeId
DECLARE @practice_instance_id        BIGINT = NULL;  -- from Practice Instances grid → Id
DECLARE @organization_id             BIGINT = NULL;  -- optional: filter to specific org

-- Pagination (match API defaults)
DECLARE @p_search  NVARCHAR(200) = N'';
DECLARE @offset    INT = 0;
DECLARE @page_size INT = 200;

-- ══════════════════════════════════════════════════════════════════════
-- AUTO-RESOLVE: if only practice_instance_id is set, derive the rest
-- ══════════════════════════════════════════════════════════════════════
IF @organization_requirement_id IS NULL AND @practice_id IS NULL AND @practice_instance_id IS NULL
BEGIN
    PRINT '=== No context set.  Showing recent Organization Requirements ===';
    SELECT TOP 25
        req.organization_requirement_id OrganizationRequirementId,
        req.organization_id OrganizationId,
        req.repository_requirement_id RepositoryRequirementId,
        req.requirement_code RequirementCode,
        req.requirement_name RequirementName,
        req.organization_control_id OrganizationControlId,
        req.org_statement_id OrgStatementId,
        req.status
    FROM grac_practice.organization_requirement req
    ORDER BY req.entered_dt DESC;

    THROW 51900, 'Set @organization_requirement_id, @practice_id, or @practice_instance_id above and rerun.', 1;
END;

-- ══════════════════════════════════════════════════════════════════════
-- SECTION 01: Context Requirement  (what the API resolves first)
-- ══════════════════════════════════════════════════════════════════════
;WITH context_requirement AS (
    SELECT DISTINCT
        req.organization_requirement_id,
        req.organization_id,
        COALESCE(req.repository_requirement_id, repo_req.requirement_id) repository_requirement_id,
        req.org_statement_id,
        req.organization_control_id,
        oc.repository_control_id,
        COALESCE(ofs.release_id, oc.release_id) context_release_id,
        req.requirement_code,
        req.requirement_name
    FROM grac_practice.organization_requirement req
    LEFT JOIN grac_practice.organization_framework_statements ofs
      ON ofs.org_statement_id = req.org_statement_id AND ofs.organization_id = req.organization_id
    LEFT JOIN grac_practice.organization_control oc
      ON oc.organization_control_id = req.organization_control_id AND oc.organization_id = req.organization_id
    LEFT JOIN GRAC_New.requirement repo_req
      ON repo_req.requirement_code = req.requirement_code AND repo_req.status = 'Active'
    WHERE (@organization_requirement_id IS NOT NULL AND req.organization_requirement_id = @organization_requirement_id)
       OR (@practice_id IS NOT NULL AND EXISTS(
            SELECT 1 FROM grac_practice.practice p
            WHERE p.practice_id = @practice_id AND p.organization_requirement_id = req.organization_requirement_id))
       OR (@practice_instance_id IS NOT NULL AND EXISTS(
            SELECT 1 FROM grac_practice.practice_instance pi
            JOIN grac_practice.practice p ON p.practice_id = pi.practice_id
            WHERE pi.practice_instance_id = @practice_instance_id
              AND p.organization_requirement_id = req.organization_requirement_id))
)
SELECT '01 Context Requirement' Section, * FROM context_requirement;

-- ══════════════════════════════════════════════════════════════════════
-- SECTION 02: Related Releases  (which framework releases are in scope)
-- ══════════════════════════════════════════════════════════════════════
;WITH context_requirement AS (
    SELECT DISTINCT
        req.organization_requirement_id, req.organization_id,
        COALESCE(req.repository_requirement_id, repo_req.requirement_id) repository_requirement_id,
        req.org_statement_id, req.organization_control_id,
        oc.repository_control_id,
        COALESCE(ofs.release_id, oc.release_id) context_release_id
    FROM grac_practice.organization_requirement req
    LEFT JOIN grac_practice.organization_framework_statements ofs
      ON ofs.org_statement_id = req.org_statement_id AND ofs.organization_id = req.organization_id
    LEFT JOIN grac_practice.organization_control oc
      ON oc.organization_control_id = req.organization_control_id AND oc.organization_id = req.organization_id
    LEFT JOIN GRAC_New.requirement repo_req
      ON repo_req.requirement_code = req.requirement_code AND repo_req.status = 'Active'
    WHERE (@organization_requirement_id IS NOT NULL AND req.organization_requirement_id = @organization_requirement_id)
       OR (@practice_id IS NOT NULL AND EXISTS(SELECT 1 FROM grac_practice.practice p WHERE p.practice_id = @practice_id AND p.organization_requirement_id = req.organization_requirement_id))
       OR (@practice_instance_id IS NOT NULL AND EXISTS(
            SELECT 1 FROM grac_practice.practice_instance pi JOIN grac_practice.practice p ON p.practice_id = pi.practice_id
            WHERE pi.practice_instance_id = @practice_instance_id AND p.organization_requirement_id = req.organization_requirement_id))
),
related_releases AS (
    SELECT DISTINCT sub.release_id, sub.artifact_id
    FROM context_requirement ctx
    JOIN grac_practice.repository_subscription sub
      ON sub.organization_id = ctx.organization_id AND sub.release_id IS NOT NULL
     AND sub.status = 'Active' AND ISNULL(sub.subscription_status,'Active') = 'Active'
    WHERE (ctx.context_release_id IS NULL OR sub.release_id = ctx.context_release_id)
    UNION
    SELECT DISTINCT COALESCE(ofs2.release_id, oc2.release_id), COALESCE(r2.artifact_id, oc2.artifact_id)
    FROM context_requirement ctx
    LEFT JOIN grac_practice.organization_framework_statements ofs2
      ON ofs2.org_statement_id = ctx.org_statement_id AND ofs2.organization_id = ctx.organization_id AND ofs2.status = 'Active'
    LEFT JOIN GRAC_New.release r2 ON r2.release_id = ofs2.release_id
    LEFT JOIN grac_practice.organization_control oc2
      ON oc2.organization_control_id = ctx.organization_control_id AND oc2.organization_id = ctx.organization_id AND oc2.status = 'Active'
    WHERE COALESCE(ofs2.release_id, oc2.release_id) IS NOT NULL
)
SELECT '02 Related Releases' Section,
    rr.release_id ReleaseId,
    art.artifact_code ArtifactCode, art.artifact_name ArtifactName,
    rel.version_no ReleaseVersion, rel.status ReleaseStatus
FROM related_releases rr
JOIN GRAC_New.release rel ON rel.release_id = rr.release_id
LEFT JOIN GRAC_New.artifact art ON art.artifact_id = COALESCE(rr.artifact_id, rel.artifact_id)
ORDER BY art.artifact_code, rel.version_no;

-- ══════════════════════════════════════════════════════════════════════
-- SECTION 03: Obligation Mapping Check
--   Does obligation_requirement_release_map have rows for this requirement + release?
-- ══════════════════════════════════════════════════════════════════════
;WITH context_requirement AS (
    SELECT DISTINCT
        req.organization_requirement_id, req.organization_id,
        COALESCE(req.repository_requirement_id, repo_req.requirement_id) repository_requirement_id,
        req.org_statement_id, req.organization_control_id,
        oc.repository_control_id,
        COALESCE(ofs.release_id, oc.release_id) context_release_id,
        req.requirement_code
    FROM grac_practice.organization_requirement req
    LEFT JOIN grac_practice.organization_framework_statements ofs
      ON ofs.org_statement_id = req.org_statement_id AND ofs.organization_id = req.organization_id
    LEFT JOIN grac_practice.organization_control oc
      ON oc.organization_control_id = req.organization_control_id AND oc.organization_id = req.organization_id
    LEFT JOIN GRAC_New.requirement repo_req
      ON repo_req.requirement_code = req.requirement_code AND repo_req.status = 'Active'
    WHERE (@organization_requirement_id IS NOT NULL AND req.organization_requirement_id = @organization_requirement_id)
       OR (@practice_id IS NOT NULL AND EXISTS(SELECT 1 FROM grac_practice.practice p WHERE p.practice_id = @practice_id AND p.organization_requirement_id = req.organization_requirement_id))
       OR (@practice_instance_id IS NOT NULL AND EXISTS(
            SELECT 1 FROM grac_practice.practice_instance pi JOIN grac_practice.practice p ON p.practice_id = pi.practice_id
            WHERE pi.practice_instance_id = @practice_instance_id AND p.organization_requirement_id = req.organization_requirement_id))
),
related_releases AS (
    SELECT DISTINCT sub.release_id, sub.artifact_id
    FROM context_requirement ctx
    JOIN grac_practice.repository_subscription sub
      ON sub.organization_id = ctx.organization_id AND sub.release_id IS NOT NULL
     AND sub.status = 'Active' AND ISNULL(sub.subscription_status,'Active') = 'Active'
    WHERE (ctx.context_release_id IS NULL OR sub.release_id = ctx.context_release_id)
    UNION
    SELECT DISTINCT COALESCE(ofs2.release_id, oc2.release_id), COALESCE(r2.artifact_id, oc2.artifact_id)
    FROM context_requirement ctx
    LEFT JOIN grac_practice.organization_framework_statements ofs2
      ON ofs2.org_statement_id = ctx.org_statement_id AND ofs2.organization_id = ctx.organization_id AND ofs2.status = 'Active'
    LEFT JOIN GRAC_New.release r2 ON r2.release_id = ofs2.release_id
    LEFT JOIN grac_practice.organization_control oc2
      ON oc2.organization_control_id = ctx.organization_control_id AND oc2.organization_id = ctx.organization_id AND oc2.status = 'Active'
    WHERE COALESCE(ofs2.release_id, oc2.release_id) IS NOT NULL
)
SELECT '03 Obligation Mapping' Section,
    dr.repository_requirement_id RepositoryRequirementId,
    rr.release_id ReleaseId,
    art.artifact_code ArtifactCode,
    rel.version_no ReleaseVersion,
    orm.obligation_id MappingObligationId,
    orm.status MappingStatus
FROM (SELECT DISTINCT repository_requirement_id, organization_id FROM context_requirement WHERE repository_requirement_id IS NOT NULL) dr
CROSS JOIN related_releases rr
JOIN GRAC_New.release rel ON rel.release_id = rr.release_id
LEFT JOIN GRAC_New.artifact art ON art.artifact_id = COALESCE(rr.artifact_id, rel.artifact_id)
LEFT JOIN GRAC_New.obligation_requirement_release_map orm
  ON orm.requirement_id = dr.repository_requirement_id
 AND orm.release_id = rr.release_id
ORDER BY art.artifact_code, rel.version_no;

-- ══════════════════════════════════════════════════════════════════════
-- SECTION 04: Obligation + Evidence Detail
--   Does requirement_obligation have rows for the mapped obligation_ids?
--   Does requirement_obligation_evidence have rows?
-- ══════════════════════════════════════════════════════════════════════
;WITH context_requirement AS (
    SELECT DISTINCT
        req.organization_requirement_id, req.organization_id,
        COALESCE(req.repository_requirement_id, repo_req.requirement_id) repository_requirement_id,
        req.org_statement_id, req.organization_control_id,
        oc.repository_control_id,
        COALESCE(ofs.release_id, oc.release_id) context_release_id
    FROM grac_practice.organization_requirement req
    LEFT JOIN grac_practice.organization_framework_statements ofs
      ON ofs.org_statement_id = req.org_statement_id AND ofs.organization_id = req.organization_id
    LEFT JOIN grac_practice.organization_control oc
      ON oc.organization_control_id = req.organization_control_id AND oc.organization_id = req.organization_id
    LEFT JOIN GRAC_New.requirement repo_req
      ON repo_req.requirement_code = req.requirement_code AND repo_req.status = 'Active'
    WHERE (@organization_requirement_id IS NOT NULL AND req.organization_requirement_id = @organization_requirement_id)
       OR (@practice_id IS NOT NULL AND EXISTS(SELECT 1 FROM grac_practice.practice p WHERE p.practice_id = @practice_id AND p.organization_requirement_id = req.organization_requirement_id))
       OR (@practice_instance_id IS NOT NULL AND EXISTS(
            SELECT 1 FROM grac_practice.practice_instance pi JOIN grac_practice.practice p ON p.practice_id = pi.practice_id
            WHERE pi.practice_instance_id = @practice_instance_id AND p.organization_requirement_id = req.organization_requirement_id))
),
related_releases AS (
    SELECT DISTINCT sub.release_id, sub.artifact_id
    FROM context_requirement ctx
    JOIN grac_practice.repository_subscription sub
      ON sub.organization_id = ctx.organization_id AND sub.release_id IS NOT NULL
     AND sub.status = 'Active' AND ISNULL(sub.subscription_status,'Active') = 'Active'
    WHERE (ctx.context_release_id IS NULL OR sub.release_id = ctx.context_release_id)
    UNION
    SELECT DISTINCT COALESCE(ofs2.release_id, oc2.release_id), COALESCE(r2.artifact_id, oc2.artifact_id)
    FROM context_requirement ctx
    LEFT JOIN grac_practice.organization_framework_statements ofs2
      ON ofs2.org_statement_id = ctx.org_statement_id AND ofs2.organization_id = ctx.organization_id AND ofs2.status = 'Active'
    LEFT JOIN GRAC_New.release r2 ON r2.release_id = ofs2.release_id
    LEFT JOIN grac_practice.organization_control oc2
      ON oc2.organization_control_id = ctx.organization_control_id AND oc2.organization_id = ctx.organization_id AND oc2.status = 'Active'
    WHERE COALESCE(ofs2.release_id, oc2.release_id) IS NOT NULL
)
SELECT '04 Obligation+Evidence Detail' Section,
    o.obligation_id ObligationId,
    o.obligation_name ObligationName,
    o.status ObligationStatus,
    roe.obligation_evidence_id EvidenceId,
    et.evidence_type_name EvidenceType,
    roe.status EvidenceStatus,
    roe.retention_requirement RetentionRequirement,
    roe.remarks Remarks
FROM (SELECT DISTINCT repository_requirement_id, organization_id FROM context_requirement WHERE repository_requirement_id IS NOT NULL) dr
JOIN related_releases rr ON 1 = 1
JOIN GRAC_New.obligation_requirement_release_map orm
  ON orm.requirement_id = dr.repository_requirement_id
 AND orm.release_id = rr.release_id
 AND orm.status = 'Active'
JOIN GRAC_New.requirement_obligation o
  ON o.obligation_id = orm.obligation_id
LEFT JOIN GRAC_New.requirement_obligation_evidence roe
  ON roe.obligation_id = o.obligation_id
LEFT JOIN GRAC_New.evidence_type_master et ON et.evidence_type_id = roe.evidence_type_id
ORDER BY o.obligation_name, et.evidence_type_name;

-- ══════════════════════════════════════════════════════════════════════
-- SECTION 05: Final View Obligations Result  (exact stored procedure output)
-- ══════════════════════════════════════════════════════════════════════
;WITH context_requirement AS (
    SELECT DISTINCT
        req.organization_requirement_id, req.organization_id,
        COALESCE(req.repository_requirement_id, repo_req.requirement_id) repository_requirement_id,
        req.org_statement_id, req.organization_control_id,
        oc.repository_control_id,
        COALESCE(ofs.release_id, oc.release_id) context_release_id
    FROM grac_practice.organization_requirement req
    LEFT JOIN grac_practice.organization_framework_statements ofs
      ON ofs.org_statement_id = req.org_statement_id AND ofs.organization_id = req.organization_id
    LEFT JOIN grac_practice.organization_control oc
      ON oc.organization_control_id = req.organization_control_id AND oc.organization_id = req.organization_id
    LEFT JOIN GRAC_New.requirement repo_req
      ON repo_req.requirement_code = req.requirement_code AND repo_req.status = 'Active'
    WHERE (@organization_requirement_id IS NOT NULL AND req.organization_requirement_id = @organization_requirement_id)
       OR (@practice_id IS NOT NULL AND EXISTS(SELECT 1 FROM grac_practice.practice p WHERE p.practice_id = @practice_id AND p.organization_requirement_id = req.organization_requirement_id))
       OR (@practice_instance_id IS NOT NULL AND EXISTS(
            SELECT 1 FROM grac_practice.practice_instance pi JOIN grac_practice.practice p ON p.practice_id = pi.practice_id
            WHERE pi.practice_instance_id = @practice_instance_id AND p.organization_requirement_id = req.organization_requirement_id))
),
related_releases AS (
    SELECT DISTINCT sub.release_id, sub.artifact_id
    FROM context_requirement ctx
    JOIN grac_practice.repository_subscription sub
      ON sub.organization_id = ctx.organization_id AND sub.release_id IS NOT NULL
     AND sub.status = 'Active' AND ISNULL(sub.subscription_status,'Active') = 'Active'
    WHERE (ctx.context_release_id IS NULL OR sub.release_id = ctx.context_release_id)
    UNION
    SELECT DISTINCT COALESCE(ofs2.release_id, oc2.release_id), COALESCE(r2.artifact_id, oc2.artifact_id)
    FROM context_requirement ctx
    LEFT JOIN grac_practice.organization_framework_statements ofs2
      ON ofs2.org_statement_id = ctx.org_statement_id AND ofs2.organization_id = ctx.organization_id AND ofs2.status = 'Active'
    LEFT JOIN GRAC_New.release r2 ON r2.release_id = ofs2.release_id
    LEFT JOIN grac_practice.organization_control oc2
      ON oc2.organization_control_id = ctx.organization_control_id AND oc2.organization_id = ctx.organization_id AND oc2.status = 'Active'
    WHERE COALESCE(ofs2.release_id, oc2.release_id) IS NOT NULL
)
-- Step 1: distinct obligations (no CROSS JOIN with releases)
SELECT
    rel.release_id FrameworkReleaseId,
    rel.FrameworkRelease,
    o.obligation_id ObligationId,
    COALESCE(NULLIF(LTRIM(RTRIM(o.obligation_name)), N''), LEFT(o.obligation_text, 300)) ObligationName,
    COALESCE(exec_freq.option_label, o.frequency_type) ExecutionFrequency,
    o.retention_requirement ObligationRetention,
    o.approval_authority ApprovalAuthority,
    o.responsibility Responsibility,
    roe.obligation_evidence_id EvidenceId,
    roe.evidence_type_id EvidenceTypeId,
    et.evidence_type_name EvidenceType,
    f.frequency_id FrequencyId,
    COALESCE(f.frequency_name, cm_freq.option_label) Frequency,
    roe.retention_requirement RetentionRequirement,
    roe.remarks Remarks
FROM (
    SELECT DISTINCT orm.obligation_id
    FROM (SELECT DISTINCT repository_requirement_id, organization_id FROM context_requirement WHERE repository_requirement_id IS NOT NULL) dr
    JOIN GRAC_New.obligation_requirement_release_map orm
      ON orm.requirement_id = dr.repository_requirement_id AND orm.status = 'Active'
) dob
JOIN GRAC_New.requirement_obligation o
  ON o.obligation_id = dob.obligation_id AND o.status = 'Active'
-- Step 2: evidence by obligation_id only — no release multiplication
JOIN GRAC_New.requirement_obligation_evidence roe
  ON roe.obligation_id = o.obligation_id AND roe.status = 'Active'
JOIN GRAC_New.evidence_type_master et ON et.evidence_type_id = roe.evidence_type_id
LEFT JOIN GRAC_New.reference_option exec_freq ON exec_freq.reference_option_id = o.execution_frequency_id
LEFT JOIN GRAC_New.reference_option cm_freq ON cm_freq.reference_option_id = roe.frequency_id
OUTER APPLY (
    SELECT TOP 1 f2.frequency_id, f2.frequency_name
    FROM grac_practice.frequency_master f2
    WHERE f2.frequency_code = cm_freq.option_value OR f2.frequency_name = cm_freq.option_label
) f
OUTER APPLY (
    SELECT TOP 1 r.release_id,
      COALESCE(a.artifact_code + N' ' + r.version_no, a.artifact_name + N' ' + r.version_no, r.version_no) FrameworkRelease
    FROM (SELECT DISTINCT repository_requirement_id, organization_id FROM context_requirement WHERE repository_requirement_id IS NOT NULL) dr2
    JOIN GRAC_New.obligation_requirement_release_map orm2
      ON orm2.requirement_id = dr2.repository_requirement_id AND orm2.obligation_id = dob.obligation_id AND orm2.status = 'Active'
    JOIN GRAC_New.release r ON r.release_id = orm2.release_id
    LEFT JOIN GRAC_New.artifact a ON a.artifact_id = r.artifact_id
) rel
WHERE (@p_search = '' OR et.evidence_type_name LIKE '%' + @p_search + '%'
       OR ISNULL(rel.FrameworkRelease, '') LIKE '%' + @p_search + '%'
       OR ISNULL(o.obligation_name, '') LIKE '%' + @p_search + '%')
ORDER BY rel.FrameworkRelease, et.display_order, et.evidence_type_name
OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;

-- ══════════════════════════════════════════════════════════════════════
-- SECTION 06: Raw table counts  (sanity check — are these tables populated?)
-- ══════════════════════════════════════════════════════════════════════
SELECT 'obligation_requirement_release_map' TableName,
    COUNT(*) TotalRows,
    SUM(CASE WHEN status = 'Active' THEN 1 ELSE 0 END) ActiveRows
FROM GRAC_New.obligation_requirement_release_map
UNION ALL
SELECT 'requirement_obligation',
    COUNT(*),
    SUM(CASE WHEN status = 'Active' THEN 1 ELSE 0 END)
FROM GRAC_New.requirement_obligation
UNION ALL
SELECT 'requirement_obligation_evidence',
    COUNT(*),
    SUM(CASE WHEN status = 'Active' THEN 1 ELSE 0 END)
FROM GRAC_New.requirement_obligation_evidence;

PRINT '=== Done.  If Section 05 is empty, check Section 03 (mapping) and Section 06 (table counts). ===';
PRINT '=== If Section 06 shows 0 rows, the obligation data has not been imported into the new tables. ===';
