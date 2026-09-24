-- =====================================================================
-- _diag_iso27001_source_control_map_status.sql
--
-- WHY THIS EXISTS
--   _diag_org_control_sync_gap.sql just showed, for ISO 27001:2022 (the
--   release this organization subscribes to on UAT):
--     - the subscription itself is fully eligible to sync
--     - grac_new.source_structure_node: 7 rows, 5 of them Active
--     - grac_new.source_control_map:   5 rows total, 0 of them Active
--     - grac_practice.organization_control: 0 rows for this release,
--       for EVERY organization on this UAT database (not just this one)
--
--   So this is not an org-specific sync gap and not something 006 or the
--   inline-sync code in 002 can fix by itself -- both require
--   scm.status = 'Active', and none of the 5 existing rows are. This
--   shows exactly what those 5 rows ARE (their real status, which node
--   and control each points to), so the next step -- activate them, or
--   reload the release's catalog data -- is based on evidence, not a
--   guess.
--
--   READ-ONLY. Set @OrganizationName (or @OrganizationId) below only if
--   you want the organization's own subscription context re-confirmed;
--   sections 1-2 are not organization-scoped, since this gap is
--   release-wide.
-- =====================================================================
SET NOCOUNT ON;

DECLARE @ReleaseId BIGINT = 1;   -- <<< ISO 27001:2022 on UAT, per the prior diagnostic; adjust if needed

-- ---------------------------------------------------------------------
-- 1. Every source_control_map row tied to this release's structure
--    nodes, whatever its status -- so we can see if it's Draft,
--    Inactive, Pending, or something else entirely.
-- ---------------------------------------------------------------------
PRINT '--- 1. source_control_map rows for release ' + CAST(@ReleaseId AS NVARCHAR(20)) + ' (any status) ---';
SELECT scm.control_id                AS ControlId,
       c.control_code                AS ControlCode,
       c.control_name                AS ControlName,
       c.status                      AS ControlStatus,
       scm.structure_node_id         AS StructureNodeId,
       n.node_reference               AS NodeReference,
       n.node_title                   AS NodeTitle,
       n.status                       AS NodeStatus,
       scm.status                     AS MapStatus,
       scm.entered_by                 AS MapEnteredBy,
       scm.entered_dt                 AS MapEnteredDt,
       scm.updated_by                 AS MapUpdatedBy,
       scm.updated_dt                 AS MapUpdatedDt
FROM   grac_new.source_control_map scm
JOIN   grac_new.source_structure_node n ON n.structure_node_id = scm.structure_node_id
LEFT JOIN grac_new.control c ON c.control_id = scm.control_id
WHERE  n.release_id = @ReleaseId
ORDER BY n.node_reference;

-- ---------------------------------------------------------------------
-- 2. Every structure node for this release, whether or not it has a
--    source_control_map row at all -- shows which of the 7 nodes are
--    simply category/parent nodes (no control expected) versus which
--    ones SHOULD have a control mapping and don't.
-- ---------------------------------------------------------------------
PRINT '';
PRINT '--- 2. All structure nodes for release ' + CAST(@ReleaseId AS NVARCHAR(20)) + ', with or without a control map row ---';
SELECT n.structure_node_id   AS StructureNodeId,
       n.node_reference       AS NodeReference,
       n.node_title           AS NodeTitle,
       n.node_level           AS NodeLevel,
       n.parent_node_id       AS ParentNodeId,
       n.status               AS NodeStatus,
       COUNT(scm.control_id)  AS MapRowCount,
       SUM(CASE WHEN scm.status = N'Active' THEN 1 ELSE 0 END) AS ActiveMapRowCount
FROM   grac_new.source_structure_node n
LEFT JOIN grac_new.source_control_map scm ON scm.structure_node_id = n.structure_node_id
WHERE  n.release_id = @ReleaseId
GROUP BY n.structure_node_id, n.node_reference, n.node_title, n.node_level, n.parent_node_id, n.status
ORDER BY n.node_reference;

-- ---------------------------------------------------------------------
-- 3. Distinct status values in play, as a quick summary.
-- ---------------------------------------------------------------------
PRINT '';
PRINT '--- 3. Distinct MapStatus values present for this release ---';
SELECT scm.status AS MapStatus, COUNT(*) AS MapRowCount
FROM   grac_new.source_control_map scm
JOIN   grac_new.source_structure_node n ON n.structure_node_id = scm.structure_node_id
WHERE  n.release_id = @ReleaseId
GROUP BY scm.status;

PRINT '';
PRINT 'If section 3 shows a single non-Active status (e.g. Draft) on all 5';
PRINT 'rows, and section 1''s control/node data looks correct and complete,';
PRINT 'the likely fix is activating those rows on UAT. If section 2 shows';
PRINT 'nodes with MapRowCount = 0 that should have a control, the release''s';
PRINT 'catalog content is incomplete on UAT, not just mis-statused.';
GO
