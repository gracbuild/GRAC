-- =====================================================================
-- _diag_ac_structure_control_gap.sql
--
-- WHY THIS EXISTS
--   Even after 349, the Risk Centre's "Map a practice" Control dropdown
--   for PCI-DSS / 7.2 shows only AC-002, never AC-001 -- although
--   Governance's own "Practices" page (grouped by Control) shows
--   REQ-AC-REVIEW-001's practice filed under AC-001.
--
--   349 fixed how a CONTROL, once offered as a candidate, counts and
--   lists the practices under it (the direct FK vs the 057 link table).
--   It did NOT touch how a candidate control is discovered in the first
--   place. sp_practice_picker_controls (LEVEL 3) discovers candidates
--   ONLY via:
--       grac_new.source_control_map (structure_node_id -> control_id)
--   -- a repository-level "this control sits under this structure node"
--   catalog fact, completely separate from how a requirement/practice
--   is actually filed (organization_requirement.org_statement_id, or
--   organization_requirement.organization_control_id).
--
--   Migration 283's own header documents THREE independent ways a
--   requirement ends up pointed at a control, of which source_control_map
--   is only one (route 2's last hop). If AC-001 was assigned via route 1
--   (repository_requirement_id -> grac_new.control_requirement_map) or
--   is otherwise correct in organization_requirement.organization_control_id
--   without ALSO having a source_control_map row for node 7.2, LEVEL 3
--   will never offer AC-001 as a row at all -- no amount of practice-count
--   fixing changes that, because the control itself never appears.
--
--   This is READ-ONLY. It does not say which system is "right" -- it
--   shows exactly what each says, so the next fix (if any) is aimed at
--   the real gap instead of guessed at.
--
-- HOW TO USE
--   Set @OrganizationName below (or @OrganizationId if you already have
--   it) and run the whole file. Every section prints what it found.
-- =====================================================================
SET NOCOUNT ON;

DECLARE @OrganizationName NVARCHAR(250) = N'YogLoans%';   -- <<< adjust if needed
DECLARE @OrganizationId   BIGINT = NULL;

SELECT @OrganizationId = organization_id
FROM   grac_practice.organization
WHERE  organization_name LIKE @OrganizationName;

IF @OrganizationId IS NULL
BEGIN
    PRINT 'Could not resolve @OrganizationId from @OrganizationName -- set @OrganizationId directly and re-run.';
    RETURN;
END
PRINT 'OrganizationId = ' + CAST(@OrganizationId AS NVARCHAR(20));

-- ---------------------------------------------------------------------
-- 1. AC-001 / AC-002 as organisation controls: their repository control
--    and release, so the next section can look them up in the catalog.
-- ---------------------------------------------------------------------
PRINT '';
PRINT '--- 1. AC-001 / AC-002 in this organisation ---';
SELECT oc.organization_control_id AS OrganizationControlId,
       oc.control_code            AS ControlCode,
       oc.control_name            AS ControlName,
       oc.repository_control_id   AS RepositoryControlId,
       oc.release_id              AS ReleaseId,
       oc.status                  AS Status
FROM   grac_practice.organization_control oc
WHERE  oc.organization_id = @OrganizationId
  AND  oc.control_code IN (N'AC-001', N'AC-002')
ORDER BY oc.control_code;

-- ---------------------------------------------------------------------
-- 2. What source_control_map (the repository catalog LEVEL 3 reads)
--    says each of those controls belongs under. If AC-001 is missing
--    here for node 7.2 but AC-002 is present, that is the whole answer.
-- ---------------------------------------------------------------------
PRINT '';
PRINT '--- 2. source_control_map: which structure node(s) claim AC-001 / AC-002 ---';
SELECT oc.control_code              AS ControlCode,
       scm.structure_node_id        AS StructureNodeId,
       n.node_reference              AS NodeReference,
       n.node_title                  AS NodeTitle,
       scm.status                    AS MapStatus
FROM   grac_practice.organization_control oc
LEFT JOIN grac_new.source_control_map scm
       ON scm.control_id = oc.repository_control_id
      AND scm.status = N'Active'
LEFT JOIN grac_new.source_structure_node n
       ON n.structure_node_id = scm.structure_node_id
      AND n.release_id = oc.release_id
WHERE  oc.organization_id = @OrganizationId
  AND  oc.control_code IN (N'AC-001', N'AC-002')
ORDER BY oc.control_code, n.node_reference;

-- ---------------------------------------------------------------------
-- 3. The two requirements themselves: their direct FK control (what 349
--    now lets the picker use), and their org_statement_id (route 2's
--    starting point -- what Governance's "Practices - 7.2" page
--    actually filters on).
-- ---------------------------------------------------------------------
PRINT '';
PRINT '--- 3. REQ-AC-DORMANT-001 / REQ-AC-REVIEW-001: direct FK and statement ---';
SELECT q.organization_requirement_id AS RequirementId,
       q.requirement_code            AS Code,
       q.organization_control_id     AS DirectFkControlId,
       oc.control_code               AS DirectFkControlCode,
       q.org_statement_id            AS OrgStatementId,
       q.repository_requirement_id   AS RepositoryRequirementId
FROM   grac_practice.organization_requirement q
LEFT JOIN grac_practice.organization_control oc
       ON oc.organization_control_id = q.organization_control_id
WHERE  q.organization_id = @OrganizationId
  AND  q.requirement_code IN (N'REQ-AC-DORMANT-001', N'REQ-AC-REVIEW-001')
ORDER BY q.requirement_code;

-- ---------------------------------------------------------------------
-- 4. Route 2's middle hop: what structure node does each requirement's
--    OWN statement resolve to? This is what Governance's "Practices -
--    7.2" page effectively filters by. Guarded -- framework_statement
--    is not on the 005 preflight contract (same caveat 283 documents).
-- ---------------------------------------------------------------------
PRINT '';
PRINT '--- 4. Requirement statement -> structure node (route 2, Governance''s own path) ---';
IF OBJECT_ID('grac_new.framework_statement','U') IS NULL
    PRINT '   grac_new.framework_statement not present on this database -- skipped.';
ELSE
    SELECT q.requirement_code             AS Code,
           ofs.org_statement_id           AS OrgStatementId,
           ofs.framework_statement_id     AS FrameworkStatementId,
           fs.structure_node_id           AS StatementStructureNodeId,
           n.node_reference                AS NodeReference,
           n.node_title                    AS NodeTitle
    FROM   grac_practice.organization_requirement q
    JOIN   grac_practice.organization_framework_statements ofs
           ON ofs.org_statement_id = q.org_statement_id
    LEFT JOIN grac_new.framework_statement fs
           ON fs.framework_statement_id = ofs.framework_statement_id
    LEFT JOIN grac_new.source_structure_node n
           ON n.structure_node_id = fs.structure_node_id
    WHERE  q.organization_id = @OrganizationId
      AND  q.requirement_code IN (N'REQ-AC-DORMANT-001', N'REQ-AC-REVIEW-001');

-- ---------------------------------------------------------------------
-- 5. Route 1's source: what does the repository's OWN requirement ->
--    control catalog say, independent of any structure node at all?
--    If this says AC-001 for REQ-AC-REVIEW-001, that is the
--    authoritative reason the direct FK is AC-001 -- and confirms the
--    gap is in source_control_map (section 2), not in the data on the
--    requirement.
-- ---------------------------------------------------------------------
PRINT '';
PRINT '--- 5. control_requirement_map (route 1, repository catalog, no structure node involved) ---';
IF OBJECT_ID('grac_new.control_requirement_map','U') IS NULL
    PRINT '   grac_new.control_requirement_map not present on this database -- skipped.';
ELSE
    SELECT q.requirement_code           AS Code,
           q.repository_requirement_id  AS RepositoryRequirementId,
           crm.control_id               AS MappedRepositoryControlId,
           oc.control_code              AS MappedControlCode,
           crm.status                   AS MapStatus
    FROM   grac_practice.organization_requirement q
    LEFT JOIN grac_new.control_requirement_map crm
           ON crm.requirement_id = q.repository_requirement_id
          AND crm.status = N'Active'
    LEFT JOIN grac_practice.organization_control oc
           ON oc.repository_control_id = crm.control_id
          AND oc.organization_id = @OrganizationId
    WHERE  q.organization_id = @OrganizationId
      AND  q.requirement_code IN (N'REQ-AC-DORMANT-001', N'REQ-AC-REVIEW-001');

PRINT '';
PRINT 'Read sections 2 and 4/5 together: if AC-001 is absent from section 2''s';
PRINT 'rows for node 7.2, but sections 4/5 show REQ-AC-REVIEW-001 genuinely';
PRINT 'belongs under 7.2 / AC-001, the gap is a missing source_control_map';
PRINT 'row (a repository catalog fact) -- a data correction, not a picker bug.';
