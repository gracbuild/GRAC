/*
  Diagnose Practice Management -> View Obligations.

  Run this in GRAC_NewPhase.
  Set @OrganizationRequirementId to the row opened from Organization Requirements / Practices.

  This checks the exact chain used by View Obligations:
    organization_requirement
      -> organization_control release context
      -> GRAC_New.requirement_obligation
      -> GRAC_New.requirement_obligation_evidence
*/

SET NOCOUNT ON;

DECLARE @OrganizationRequirementId BIGINT = NULL; -- TODO: set this from the Organization Requirements grid Id

IF @OrganizationRequirementId IS NULL
BEGIN
    SELECT TOP (25)
        q.organization_requirement_id OrganizationRequirementId,
        q.organization_id OrganizationId,
        q.organization_control_id OrganizationControlId,
        q.repository_requirement_id RepositoryRequirementId,
        q.requirement_code RequirementCode,
        q.requirement_name RequirementName,
        q.status RequirementStatus
    FROM grac_practice.organization_requirement q
    ORDER BY q.entered_dt DESC;

    THROW 51801, 'Set @OrganizationRequirementId using one of the rows above and rerun.', 1;
END;

;WITH context_requirement AS (
    SELECT
        req.organization_requirement_id,
        req.organization_id,
        req.repository_requirement_id,
        req.organization_control_id,
        oc.repository_control_id,
        oc.release_id context_release_id,
        oc.artifact_id context_artifact_id,
        req.requirement_code,
        req.requirement_name
    FROM grac_practice.organization_requirement req
    LEFT JOIN grac_practice.organization_control oc
      ON oc.organization_control_id = req.organization_control_id
    WHERE req.organization_requirement_id = @OrganizationRequirementId
),
related_releases AS (
    SELECT DISTINCT oc2.release_id, oc2.artifact_id
    FROM context_requirement ctx
    JOIN grac_practice.organization_control oc2
      ON oc2.organization_id = ctx.organization_id
     AND oc2.status = 'Active'
     AND oc2.release_id IS NOT NULL
     AND (
        (ctx.repository_control_id IS NOT NULL AND oc2.repository_control_id = ctx.repository_control_id)
        OR oc2.organization_control_id = ctx.organization_control_id
     )
)
SELECT
    '01 Context Requirement' Section,
    ctx.*
FROM context_requirement ctx;

;WITH context_requirement AS (
    SELECT req.organization_requirement_id, req.organization_id, req.repository_requirement_id, req.organization_control_id,
           oc.repository_control_id
    FROM grac_practice.organization_requirement req
    LEFT JOIN grac_practice.organization_control oc ON oc.organization_control_id = req.organization_control_id
    WHERE req.organization_requirement_id = @OrganizationRequirementId
),
related_releases AS (
    SELECT DISTINCT oc2.release_id, oc2.artifact_id
    FROM context_requirement ctx
    JOIN grac_practice.organization_control oc2
      ON oc2.organization_id = ctx.organization_id
     AND oc2.status = 'Active'
     AND oc2.release_id IS NOT NULL
     AND ((ctx.repository_control_id IS NOT NULL AND oc2.repository_control_id = ctx.repository_control_id)
       OR oc2.organization_control_id = ctx.organization_control_id)
)
SELECT
    '02 Related Releases' Section,
    rr.release_id ReleaseId,
    art.artifact_code ArtifactCode,
    art.artifact_name ArtifactName,
    rel.version_no ReleaseVersion,
    rel.status ReleaseStatus
FROM related_releases rr
JOIN GRAC_New.release rel ON rel.release_id = rr.release_id
LEFT JOIN GRAC_New.artifact art ON art.artifact_id = COALESCE(rr.artifact_id, rel.artifact_id)
ORDER BY art.artifact_code, rel.version_no;

;WITH context_requirement AS (
    SELECT req.organization_requirement_id, req.organization_id, req.repository_requirement_id, req.organization_control_id,
           oc.repository_control_id
    FROM grac_practice.organization_requirement req
    LEFT JOIN grac_practice.organization_control oc ON oc.organization_control_id = req.organization_control_id
    WHERE req.organization_requirement_id = @OrganizationRequirementId
),
related_releases AS (
    SELECT DISTINCT oc2.release_id, oc2.artifact_id
    FROM context_requirement ctx
    JOIN grac_practice.organization_control oc2
      ON oc2.organization_id = ctx.organization_id
     AND oc2.status = 'Active'
     AND oc2.release_id IS NOT NULL
     AND ((ctx.repository_control_id IS NOT NULL AND oc2.repository_control_id = ctx.repository_control_id)
       OR oc2.organization_control_id = ctx.organization_control_id)
)
SELECT
    '03 Obligation Match' Section,
    ctx.repository_requirement_id RepositoryRequirementId,
    req.requirement_code RequirementCode,
    rr.release_id ReleaseId,
    art.artifact_code ArtifactCode,
    rel.version_no ReleaseVersion,
    ro.obligation_id ObligationId,
    COUNT(roe.obligation_evidence_id) EvidenceRowCount
FROM context_requirement ctx
JOIN GRAC_New.requirement req ON req.requirement_id = ctx.repository_requirement_id
JOIN related_releases rr ON 1 = 1
JOIN GRAC_New.release rel ON rel.release_id = rr.release_id
LEFT JOIN GRAC_New.artifact art ON art.artifact_id = rel.artifact_id
LEFT JOIN GRAC_New.requirement_obligation ro
  ON ro.requirement_id = ctx.repository_requirement_id
 AND ro.release_id = rr.release_id
 AND ro.status = 'Active'
LEFT JOIN GRAC_New.requirement_obligation_evidence roe
  ON roe.obligation_id = ro.obligation_id
 AND roe.status = 'Active'
GROUP BY ctx.repository_requirement_id, req.requirement_code, rr.release_id, art.artifact_code, rel.version_no, ro.obligation_id
ORDER BY art.artifact_code, rel.version_no;

;WITH context_requirement AS (
    SELECT req.organization_requirement_id, req.organization_id, req.repository_requirement_id, req.organization_control_id,
           oc.repository_control_id
    FROM grac_practice.organization_requirement req
    LEFT JOIN grac_practice.organization_control oc ON oc.organization_control_id = req.organization_control_id
    WHERE req.organization_requirement_id = @OrganizationRequirementId
),
related_releases AS (
    SELECT DISTINCT oc2.release_id, oc2.artifact_id
    FROM context_requirement ctx
    JOIN grac_practice.organization_control oc2
      ON oc2.organization_id = ctx.organization_id
     AND oc2.status = 'Active'
     AND oc2.release_id IS NOT NULL
     AND ((ctx.repository_control_id IS NOT NULL AND oc2.repository_control_id = ctx.repository_control_id)
       OR oc2.organization_control_id = ctx.organization_control_id)
)
SELECT
    '04 View Obligations Result' Section,
    COALESCE(art.artifact_code + N' ' + rel.version_no, rel.version_no) FrameworkRelease,
    et.evidence_type_name EvidenceType,
    freq.option_label Frequency,
    roe.retention_requirement RetentionRequirement,
    roe.remarks Remarks
FROM context_requirement ctx
JOIN related_releases rr ON 1 = 1
JOIN GRAC_New.release rel ON rel.release_id = rr.release_id
LEFT JOIN GRAC_New.artifact art ON art.artifact_id = COALESCE(rr.artifact_id, rel.artifact_id)
JOIN GRAC_New.requirement_obligation ro
  ON ro.requirement_id = ctx.repository_requirement_id
 AND ro.release_id = rr.release_id
 AND ro.status = 'Active'
JOIN GRAC_New.requirement_obligation_evidence roe
  ON roe.obligation_id = ro.obligation_id
 AND roe.status = 'Active'
JOIN GRAC_New.evidence_type_master et ON et.evidence_type_id = roe.evidence_type_id
LEFT JOIN GRAC_New.reference_option freq ON freq.reference_option_id = roe.frequency_id
ORDER BY FrameworkRelease, et.display_order, et.evidence_type_name;
