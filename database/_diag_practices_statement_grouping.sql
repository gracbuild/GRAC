-- _diag_practices_statement_grouping.sql  (READ-ONLY; SSMS against the DB the API uses)
-- Why does Organization Practices show "No practices found" for a statement
-- that has mapped practices? Walks every condition the grid's statement
-- grouping (QueryOrganizationRequirementFallbackAsync, grp, 2026-10-18)
-- applies, for ONE statement, and reports which one each practice fails.
-- Set the three values below. @statement_reference is the code shown in
-- Control Statements (e.g. N'A.5.15').
SET NOCOUNT ON;
DECLARE @organization_id     BIGINT        = 0;     -- e.g. DEMO-BANK's organization_id
DECLARE @release_id          BIGINT        = 0;     -- ISO-27001 2022's release_id
DECLARE @statement_reference NVARCHAR(100) = N'';

-- 1. The subscription (repository releases need an Active subscription).
SELECT N'1 subscription' Step, s.subscription_id, s.release_id, s.status, s.subscription_status, s.owner_id,
       CASE WHEN s.owner_id IS NULL THEN N'NO OWNER: statements of this release never count as Applicable for the grid' ELSE N'ok' END Verdict
FROM grac_practice.repository_subscription s
WHERE s.organization_id=@organization_id AND s.release_id=@release_id;

-- 2. The statement row the grid groups under.
SELECT N'2 statement' Step, ofs.org_statement_id, ofs.framework_statement_id, ofs.statement_reference, ofs.statement_title,
       ofs.source_type, ofs.status, ofs.copied_dt, ofs.structure_node_id,
       aps.status_name Applicability,
       n.structure_node_id NodeId, n.status NodeStatus,
       CASE
         WHEN ofs.status<>'Active' THEN N'FAIL: statement row not Active'
         WHEN ofs.source_type=N'Repository' AND ofs.copied_dt IS NULL THEN N'FAIL: statement not copied (copied_dt NULL)'
         WHEN ofs.source_type=N'Repository' AND n.structure_node_id IS NULL THEN N'FAIL: no Active structure node for this statement'
         ELSE N'ok'
       END Verdict
FROM grac_practice.organization_framework_statements ofs
LEFT JOIN grac_practice.applicability_status_master aps ON aps.applicability_status_id=ofs.applicability_status_id
LEFT JOIN grac_practice.organization_statement_structure_node n ON n.organization_id=ofs.organization_id
    AND n.structure_node_id=ofs.structure_node_id AND n.status='Active'
WHERE ofs.organization_id=@organization_id
  AND ofs.release_id=@release_id
  AND ofs.statement_reference=@statement_reference;

-- 3. Every practice linked to that statement (own statement or mapping row),
--    with the first grid condition it fails.
;WITH st AS (
    SELECT ofs.org_statement_id, ofs.framework_statement_id
    FROM grac_practice.organization_framework_statements ofs
    WHERE ofs.organization_id=@organization_id AND ofs.release_id=@release_id
      AND ofs.statement_reference=@statement_reference
), linked AS (
    SELECT q.organization_requirement_id, N'own statement' LinkedBy, CAST(NULL AS NVARCHAR(20)) MappingStatus
    FROM grac_practice.organization_requirement q JOIN st ON st.org_statement_id=q.org_statement_id
    WHERE q.organization_id=@organization_id
    UNION ALL
    SELECT m.org_practice_id, N'mapping row', m.status
    FROM grac_practice.organization_statement_practice_mapping m
    JOIN st ON st.org_statement_id=m.org_statement_id
            OR (m.org_statement_id IS NULL AND m.framework_statement_id=st.framework_statement_id)
    WHERE m.organization_id=@organization_id
)
SELECT N'3 practice' Step, q.organization_requirement_id, q.requirement_code, q.requirement_name, q.origin_type, q.status,
       l.LinkedBy, l.MappingStatus,
       CASE
         WHEN l.LinkedBy=N'mapping row' AND l.MappingStatus<>'Active' THEN N'FAIL: mapping row is not Active'
         WHEN q.status<>'Active' THEN N'note: practice is not Active'
         ELSE N'ok -- if the grid still shows nothing, check the API was restarted after the 2026-10-18 change, and View Data Scope (460) for the signed-in user'
       END Verdict
FROM linked l
JOIN grac_practice.organization_requirement q ON q.organization_requirement_id=l.organization_requirement_id
ORDER BY q.requirement_code;
