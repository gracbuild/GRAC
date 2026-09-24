-- =====================================================================
-- _diag_practice_picker.sql
--
-- Walks the EXACT joins sp_practice_picker_* uses (migration 282) and
-- reports where the chain goes empty:
--
--     Framework -> Source Structure -> Control -> Practice
--
-- Read-only. Nothing is written.
--
-- Set @OrganizationId below, run it, and send back the output. The
-- section that returns 0 rows is the broken hop.
-- =====================================================================
SET NOCOUNT ON;

DECLARE @OrganizationId BIGINT = 4;   -- <<< set this

PRINT '=================================================================';
PRINT ' Practice Picker diagnostic for organization ' + CAST(@OrganizationId AS NVARCHAR(20));
PRINT '=================================================================';

-- ---------------------------------------------------------------------
-- 0. The last join first -- it is the one 283 did NOT populate.
--    283 repaired organization_requirement + organization_control_requirement,
--    but the picker's final hop is to grac_practice.practice, whose rows
--    are only created by the practice / practice-instance save paths.
--    A requirement with no practice row is invisible to the picker no
--    matter how correct the control mapping is.
-- ---------------------------------------------------------------------
PRINT '';
PRINT '--- 0. Requirement -> practice row (the most likely gap) ---';
SELECT q.organization_requirement_id           AS RequirementId,
       q.requirement_code                      AS Code,
       q.requirement_name                      AS Name,
       q.organization_control_id               AS ControlId,
       CASE WHEN p.practice_id IS NULL THEN 'MISSING - invisible to picker'
            ELSE 'ok' END                      AS PracticeRow,
       p.practice_id                           AS PracticeId,
       p.status                                AS PracticeStatus
FROM   grac_practice.organization_requirement q
LEFT JOIN grac_practice.practice p
       ON p.organization_requirement_id = q.organization_requirement_id
      AND p.organization_id = q.organization_id
      AND p.status = N'Active'
WHERE  q.organization_id = @OrganizationId
  AND  q.status = N'Active'
ORDER BY CASE WHEN p.practice_id IS NULL THEN 0 ELSE 1 END, q.requirement_code;

-- ---------------------------------------------------------------------
-- 1. Level 1 -- exactly what sp_practice_picker_frameworks returns.
-- ---------------------------------------------------------------------
PRINT '';
PRINT '--- 1. Frameworks ---';
EXEC grac_practice.sp_practice_picker_frameworks @organization_id = @OrganizationId;

-- ---------------------------------------------------------------------
-- 2/3/4. Walk every release -> node -> control -> practice count in one
--        pass, using the picker's own join shape. Any row with
--        PracticeCount = 0 is a dead end the user can reach.
-- ---------------------------------------------------------------------
PRINT '';
PRINT '--- 2-4. Structure -> Control -> Practice counts ---';
;WITH subs AS (
    SELECT DISTINCT s.release_id
    FROM   grac_practice.repository_subscription s
    WHERE  s.organization_id = @OrganizationId
      AND  s.status = N'Active'
      AND  ISNULL(s.subscription_status, N'Active') = N'Active'
      AND  s.release_id IS NOT NULL
)
SELECT n.release_id                              AS ReleaseId,
       n.structure_node_id                       AS StructureNodeId,
       COALESCE(NULLIF(n.node_reference, N'') + N' - ', N'') + n.node_title AS StructureName,
       oc.organization_control_id                AS ControlId,
       oc.control_code                           AS ControlCode,
       COUNT(DISTINCT q.organization_requirement_id) AS RequirementsMapped,
       COUNT(DISTINCT p.practice_id)             AS PracticeCount
FROM   subs
JOIN   grac_new.source_structure_node n
       ON n.release_id = subs.release_id AND n.status = N'Active'
JOIN   grac_new.source_control_map scm
       ON scm.structure_node_id = n.structure_node_id AND scm.status = N'Active'
JOIN   grac_practice.organization_control oc
       ON oc.repository_control_id = scm.control_id
      AND oc.organization_id = @OrganizationId
      AND oc.release_id = subs.release_id
      AND oc.status = N'Active'
LEFT JOIN grac_practice.organization_control_requirement ocr
       ON ocr.organization_control_id = oc.organization_control_id
      AND ocr.status = N'Active'
LEFT JOIN grac_practice.organization_requirement q
       ON q.organization_requirement_id = ocr.organization_requirement_id
      AND q.status = N'Active'
LEFT JOIN grac_practice.practice p
       ON p.organization_requirement_id = q.organization_requirement_id
      AND p.organization_id = @OrganizationId
      AND p.status = N'Active'
GROUP BY n.release_id, n.structure_node_id, n.node_reference, n.node_title,
         oc.organization_control_id, oc.control_code
ORDER BY n.release_id, n.structure_node_id, oc.control_code;

-- ---------------------------------------------------------------------
-- 5. Where the mapped controls actually sit. If 283 attached a practice
--    to a control that no structure node reaches (release mismatch, or
--    a control with a NULL release_id), the picker can never surface it.
-- ---------------------------------------------------------------------
PRINT '';
PRINT '--- 5. Are the mapped controls reachable from a structure node? ---';
SELECT oc.organization_control_id  AS ControlId,
       oc.control_code             AS ControlCode,
       oc.release_id               AS ControlReleaseId,
       oc.repository_control_id    AS RepoControlId,
       COUNT(DISTINCT ocr.organization_requirement_id) AS RequirementsMapped,
       COUNT(DISTINCT scm.structure_node_id)           AS ReachableFromNodes,
       CASE WHEN oc.release_id IS NULL THEN 'control has NULL release_id'
            WHEN COUNT(DISTINCT scm.structure_node_id) = 0 THEN 'NOT reachable from any node'
            ELSE 'ok' END          AS Verdict
FROM   grac_practice.organization_control oc
JOIN   grac_practice.organization_control_requirement ocr
       ON ocr.organization_control_id = oc.organization_control_id
      AND ocr.status = N'Active'
LEFT JOIN grac_new.source_control_map scm
       ON scm.control_id = oc.repository_control_id
      AND scm.status = N'Active'
LEFT JOIN grac_new.source_structure_node n
       ON n.structure_node_id = scm.structure_node_id
      AND n.release_id = oc.release_id
      AND n.status = N'Active'
WHERE  oc.organization_id = @OrganizationId
  AND  oc.status = N'Active'
GROUP BY oc.organization_control_id, oc.control_code, oc.release_id, oc.repository_control_id
ORDER BY Verdict, oc.control_code;

-- ---------------------------------------------------------------------
-- 6. Bottom line -- what the picker's practice level would return for
--    every control that has any mapping at all.
-- ---------------------------------------------------------------------
PRINT '';
PRINT '--- 6. sp_practice_picker_practices result per mapped control ---';
DECLARE @cid BIGINT;
DECLARE c CURSOR LOCAL FAST_FORWARD FOR
    SELECT DISTINCT ocr.organization_control_id
    FROM   grac_practice.organization_control_requirement ocr
    JOIN   grac_practice.organization_control oc
           ON oc.organization_control_id = ocr.organization_control_id
          AND oc.organization_id = @OrganizationId
    WHERE  ocr.status = N'Active';
OPEN c; FETCH NEXT FROM c INTO @cid;
WHILE @@FETCH_STATUS = 0
BEGIN
    PRINT '  control ' + CAST(@cid AS NVARCHAR(20)) + ':';
    EXEC grac_practice.sp_practice_picker_practices
         @organization_id = @OrganizationId, @organization_control_id = @cid;
    FETCH NEXT FROM c INTO @cid;
END
CLOSE c; DEALLOCATE c;

PRINT '';
PRINT 'Diagnostic complete.';
GO
