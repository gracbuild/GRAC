-- =====================================================================
-- 030 Diagnose Source Statement flow
-- Verifies each step of:
--   Repository Framework Statement -> Practice Mapping ->
--   Organization Subscription -> Organization Source Statement view
-- Run each section and note where the row count first becomes zero.
-- Set the two variables below before running.
-- =====================================================================
SET NOCOUNT ON;

DECLARE @organization_id BIGINT = (SELECT TOP 1 organization_id FROM grac_practice.organization WHERE organization_name LIKE N'%YogLoans%');
DECLARE @release_id BIGINT = (
    SELECT TOP 1 r.release_id
    FROM grac_new.release r
    JOIN grac_new.artifact a ON a.artifact_id=r.artifact_id
    WHERE a.artifact_code LIKE N'%RBI-IT-GOV%' OR a.artifact_name LIKE N'%RBI IT Governance%'
    ORDER BY r.version_no DESC);

SELECT @organization_id OrganizationId, @release_id ReleaseId;

-- Step 1. Repository: Framework Statements for the release ------------------
SELECT '1. Repository framework statements (Active)' Step, COUNT(*) Rows_
FROM grac_new.framework_statement fs
WHERE fs.release_id=@release_id AND fs.status='Active';

SELECT fs.framework_statement_id, fs.structure_node_id, fs.statement_reference,
       fs.statement_title, fs.status
FROM grac_new.framework_statement fs
WHERE fs.release_id=@release_id
ORDER BY fs.display_order, fs.statement_reference;

-- Step 1b. Statement -> structure node linkage (statements dropped here have
-- a NULL/inactive/wrong-release node and will not appear in the tree) --------
SELECT '1b. Statements attached to an Active node of this release' Step, COUNT(*) Rows_
FROM grac_new.framework_statement fs
JOIN grac_new.source_structure_node n ON n.structure_node_id=fs.structure_node_id
   AND n.release_id=@release_id AND n.status='Active'
WHERE fs.release_id=@release_id AND fs.status='Active';

SELECT fs.framework_statement_id, fs.statement_reference, fs.structure_node_id,
       n.node_reference, n.status NodeStatus, n.release_id NodeReleaseId
FROM grac_new.framework_statement fs
LEFT JOIN grac_new.source_structure_node n ON n.structure_node_id=fs.structure_node_id
WHERE fs.release_id=@release_id AND fs.status='Active'
  AND (n.structure_node_id IS NULL OR n.status<>'Active' OR n.release_id<>@release_id);
-- ^ any rows here are statements that will NOT render in the tree.

-- Step 2. Statement mappings (requirement / control) -------------------------
SELECT '2a. Statement->Requirement mappings' Step, COUNT(*) Rows_
FROM grac_new.framework_statement fs
JOIN grac_new.framework_statement_requirement_map m ON m.framework_statement_id=fs.framework_statement_id AND m.status='Active'
WHERE fs.release_id=@release_id AND fs.status='Active';

SELECT '2b. Statement->Control mappings' Step, COUNT(*) Rows_
FROM grac_new.framework_statement fs
JOIN grac_new.framework_statement_control_map m ON m.framework_statement_id=fs.framework_statement_id AND m.status='Active'
WHERE fs.release_id=@release_id AND fs.status='Active';

-- Step 3. Organization subscription ------------------------------------------
SELECT '3. Active subscription for org+release' Step, COUNT(*) Rows_
FROM grac_practice.repository_subscription s
WHERE s.organization_id=@organization_id AND s.release_id=@release_id
  AND s.status='Active' AND ISNULL(s.subscription_status,'Active')='Active';

-- Step 4. Organization applicability rows (enrichment only; the view must NOT
-- depend on these existing) ---------------------------------------------------
SELECT '4. organization_framework_statements rows' Step, COUNT(*) Rows_
FROM grac_practice.organization_framework_statements ofs
WHERE ofs.organization_id=@organization_id AND ofs.release_id=@release_id AND ofs.status='Active';

-- Step 5. Exactly what the drill-down statement query returns -----------------
SELECT '5. Drill-down statement rows' Step, COUNT(*) Rows_
FROM grac_new.framework_statement fs
JOIN grac_new.source_structure_node n ON n.structure_node_id=fs.structure_node_id
   AND n.release_id=@release_id AND n.status='Active'
LEFT JOIN grac_practice.organization_framework_statements ofs
   ON ofs.framework_statement_id=fs.framework_statement_id
  AND ofs.organization_id=@organization_id
  AND ofs.release_id=@release_id
  AND ofs.status='Active'
WHERE fs.release_id=@release_id AND fs.status='Active';

SELECT fs.statement_reference, fs.statement_title,
       n.node_reference, ofs.org_statement_id,
       COALESCE(aps.status_name,N'Not Updated') ApplicabilityStatus
FROM grac_new.framework_statement fs
JOIN grac_new.source_structure_node n ON n.structure_node_id=fs.structure_node_id
   AND n.release_id=@release_id AND n.status='Active'
LEFT JOIN grac_practice.organization_framework_statements ofs
   ON ofs.framework_statement_id=fs.framework_statement_id
  AND ofs.organization_id=@organization_id
  AND ofs.release_id=@release_id
  AND ofs.status='Active'
LEFT JOIN grac_practice.applicability_status_master aps ON aps.applicability_status_id=ofs.applicability_status_id
WHERE fs.release_id=@release_id AND fs.status='Active'
ORDER BY n.display_order, fs.display_order, fs.statement_reference;

-- Expectation: Step 1b count = Step 5 count = summary "Total Statements".
