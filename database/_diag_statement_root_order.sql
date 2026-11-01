-- =====================================================================
-- _diag_statement_root_order.sql  (read-only)
-- Control Statements order check: the ROOT source-structure nodes
-- (parent_node_id NULL) of one organization + framework release, with the
-- display_order the Control Statements page sorts by (2026-10-08).
-- Set @org_id and @release_label (as shown in the release dropdown, e.g.
-- 'ISO 27001 2022v2'), or @release_id directly.
-- =====================================================================
SET NOCOUNT ON;
DECLARE @org_id        BIGINT        = 9;                    -- SD
DECLARE @release_label NVARCHAR(200) = N'ISO 27001 2022v2';
DECLARE @release_id    BIGINT        = NULL;                 -- or set directly

IF @release_id IS NULL
    SELECT TOP 1 @release_id = r.release_id
    FROM   GRAC_New.release r
    LEFT   JOIN GRAC_New.artifact a ON a.artifact_id = r.artifact_id
    WHERE  COALESCE(a.artifact_code + N' ' + r.version_no, a.artifact_name + N' ' + r.version_no, r.version_no) = @release_label;

SELECT @org_id AS OrganizationId, @release_id AS ReleaseId;

-- 1. Root nodes, in the order the page now uses.
SELECT n.structure_node_id, n.node_reference, n.node_title, n.node_level,
       n.display_order, n.status, n.lifecycle_status,
       (SELECT COUNT(*) FROM grac_practice.organization_statement_structure_node c
         WHERE c.organization_id = n.organization_id AND c.release_id = n.release_id
           AND c.parent_node_id = n.structure_node_id AND c.status = N'Active') AS ChildNodes
FROM   grac_practice.organization_statement_structure_node n
WHERE  n.organization_id = @org_id AND n.release_id = @release_id
  AND  n.parent_node_id IS NULL
ORDER  BY CASE WHEN n.display_order IS NULL THEN 1 ELSE 0 END, n.display_order, n.node_reference;

-- 2. Active nodes whose parent is NOT an active node of this org/release.
--    The page treats such a node as a root, so its own display_order
--    decides its place -- the usual reason a branch jumps ahead.
SELECT n.structure_node_id, n.node_reference, n.parent_node_id, n.display_order
FROM   grac_practice.organization_statement_structure_node n
WHERE  n.organization_id = @org_id AND n.release_id = @release_id AND n.status = N'Active'
  AND  n.parent_node_id IS NOT NULL
  AND  NOT EXISTS (SELECT 1 FROM grac_practice.organization_statement_structure_node p
                   WHERE p.organization_id = n.organization_id AND p.release_id = n.release_id
                     AND p.structure_node_id = n.parent_node_id AND p.status = N'Active');
