-- =====================================================================
-- DIAGNOSTIC -- "the Control combo does not fill, so no practice can be
--                selected"
--
-- READ-ONLY. No CREATE, ALTER, INSERT, UPDATE, DELETE. Safe on
-- production.
--
-- WHAT THIS ANSWERS
--   The picker cascade is framework -> structure -> control -> practice.
--   A control is only useful if practices hang off it, through:
--
--     organization_control
--        -> organization_control_requirement   (status Active)
--        -> organization_requirement           (status Active)
--        -> practice                           (status Active, same org)
--
--   sp_practice_picker_controls counts that chain as PracticeCount, and
--   sp_practice_picker_practices walks the SAME chain to list them -- so
--   a count of 0 means the practice query would return nothing.
--
--   The UI used to HIDE controls with a count of 0, which emptied the
--   Control dropdown and left the practice level stuck on "Select a
--   control first" with no reason on screen. They are now listed and
--   disabled. This file says WHICH link of the chain is missing.
--
-- HOW TO USE
--   Set @OrganizationId. Optionally set @StructureNodeId to the source
--   structure you were browsing (-1 is the "ORG-PRACTICES" bucket).
-- =====================================================================
SET NOCOUNT ON;

DECLARE @OrganizationId  BIGINT = NULL;   -- <<< required
DECLARE @StructureNodeId BIGINT = NULL;   -- <<< optional

IF @OrganizationId IS NULL
BEGIN
    PRINT 'Set @OrganizationId at the top of this file and re-run.';
    RETURN;
END

PRINT '=== 1. Controls, and where their practice chain breaks ======';
SELECT oc.organization_control_id                AS OrganizationControlId,
       oc.control_code                           AS ControlCode,
       oc.control_name                           AS ControlName,
       oc.status                                 AS ControlStatus,
       -- each link counted separately, so the break is visible
       (SELECT COUNT(*) FROM grac_practice.organization_control_requirement ocr
         WHERE ocr.organization_control_id = oc.organization_control_id)            AS ReqLinks_Any,
       (SELECT COUNT(*) FROM grac_practice.organization_control_requirement ocr
         WHERE ocr.organization_control_id = oc.organization_control_id
           AND ocr.status = N'Active')                                              AS ReqLinks_Active,
       (SELECT COUNT(*)
          FROM grac_practice.organization_control_requirement ocr
          JOIN grac_practice.organization_requirement q
            ON q.organization_requirement_id = ocr.organization_requirement_id
         WHERE ocr.organization_control_id = oc.organization_control_id
           AND ocr.status = N'Active' AND q.status = N'Active')                     AS Requirements_Active,
       (SELECT COUNT(DISTINCT p.practice_id)
          FROM grac_practice.organization_control_requirement ocr
          JOIN grac_practice.organization_requirement q
            ON q.organization_requirement_id = ocr.organization_requirement_id
          JOIN grac_practice.practice p
            ON p.organization_requirement_id = q.organization_requirement_id
         WHERE ocr.organization_control_id = oc.organization_control_id
           AND ocr.status = N'Active' AND q.status = N'Active'
           AND p.organization_id = @OrganizationId)                                 AS Practices_AnyStatus,
       -- THIS is the number the picker uses
       (SELECT COUNT(DISTINCT p.practice_id)
          FROM grac_practice.organization_control_requirement ocr
          JOIN grac_practice.organization_requirement q
            ON q.organization_requirement_id = ocr.organization_requirement_id
          JOIN grac_practice.practice p
            ON p.organization_requirement_id = q.organization_requirement_id
         WHERE ocr.organization_control_id = oc.organization_control_id
           AND ocr.status = N'Active' AND q.status = N'Active'
           AND p.organization_id = @OrganizationId
           AND p.status = N'Active')                                                AS PracticeCount_AsPickerSeesIt,
       CASE
         WHEN (SELECT COUNT(*) FROM grac_practice.organization_control_requirement ocr
                WHERE ocr.organization_control_id = oc.organization_control_id) = 0
              THEN 'no requirement is linked to this control at all'
         WHEN (SELECT COUNT(*) FROM grac_practice.organization_control_requirement ocr
                WHERE ocr.organization_control_id = oc.organization_control_id
                  AND ocr.status = N'Active') = 0
              THEN 'requirement links exist but none are Active'
         WHEN (SELECT COUNT(DISTINCT p.practice_id)
                 FROM grac_practice.organization_control_requirement ocr
                 JOIN grac_practice.organization_requirement q
                   ON q.organization_requirement_id = ocr.organization_requirement_id
                 JOIN grac_practice.practice p
                   ON p.organization_requirement_id = q.organization_requirement_id
                WHERE ocr.organization_control_id = oc.organization_control_id
                  AND ocr.status = N'Active' AND q.status = N'Active'
                  AND p.organization_id = @OrganizationId) = 0
              THEN 'requirements are there, but no practice hangs off them'
         WHEN (SELECT COUNT(DISTINCT p.practice_id)
                 FROM grac_practice.organization_control_requirement ocr
                 JOIN grac_practice.organization_requirement q
                   ON q.organization_requirement_id = ocr.organization_requirement_id
                 JOIN grac_practice.practice p
                   ON p.organization_requirement_id = q.organization_requirement_id
                WHERE ocr.organization_control_id = oc.organization_control_id
                  AND ocr.status = N'Active' AND q.status = N'Active'
                  AND p.organization_id = @OrganizationId
                  AND p.status = N'Active') = 0
              THEN 'practices exist but NONE are Active -- this is the usual cause'
         ELSE 'OK -- the picker will offer this control'
       END                                                                          AS Verdict
  FROM grac_practice.organization_control oc
 WHERE oc.organization_id = @OrganizationId
   AND oc.status = N'Active'
 ORDER BY PracticeCount_AsPickerSeesIt, oc.control_code;

PRINT '';
PRINT '=== 2. Does the structure node reach any control? ===========';
-- The non-ORG branch of sp_practice_picker_controls is driven from
-- grac_new.source_control_map. No rows here means an empty Control
-- dropdown for a different reason: the structure maps to nothing.
IF @StructureNodeId IS NULL OR @StructureNodeId = -1
    PRINT '   (set @StructureNodeId to a real node to run this section)';
ELSE
    SELECT scm.structure_node_id      AS StructureNodeId,
           scm.control_id             AS RepositoryControlId,
           scm.status                 AS MapStatus,
           oc.organization_control_id AS OrganizationControlId,
           oc.control_code            AS ControlCode,
           oc.release_id              AS ReleaseId,
           CASE WHEN oc.organization_control_id IS NULL
                THEN 'mapped in grac_new but NOT adopted into this organisation'
                ELSE 'adopted' END    AS Verdict
      FROM grac_new.source_control_map scm
      LEFT JOIN grac_practice.organization_control oc
             ON oc.repository_control_id = scm.control_id
            AND oc.organization_id       = @OrganizationId
            AND oc.status                = N'Active'
     WHERE scm.structure_node_id = @StructureNodeId
       AND scm.status = N'Active'
     ORDER BY oc.control_code;

PRINT '';
PRINT '=== 3. Practices that exist but are not Active ==============';
-- The single most common reason a control counts 0: the practices are
-- there but their status is not Active, so both picker procedures skip
-- them identically.
SELECT p.practice_id     AS PracticeId,
       p.practice_code   AS PracticeCode,
       p.practice_name   AS PracticeName,
       p.status          AS PracticeStatus,
       p.organization_requirement_id AS OrganizationRequirementId
  FROM grac_practice.practice p
 WHERE p.organization_id = @OrganizationId
   AND ISNULL(p.status, N'') <> N'Active'
 ORDER BY p.practice_code;

PRINT '';
PRINT '=== 4. THE USUAL ANSWER: is the 057 link table populated? ===';
-- THIS IS THE SECTION THAT USUALLY SETTLES IT.
--
-- A requirement points at its control TWO ways:
--   (a) organization_requirement.organization_control_id  -- direct FK
--   (b) organization_control_requirement                  -- 057's
--       many-to-many link table
--
-- The practice picker (282) reads ONLY (b). Migration 283's header
-- spells out the consequence: 057's own backfill is
-- "WHERE r.organization_control_id IS NOT NULL", so a requirement whose
-- direct column is NULL never gets a link row -- and "a practice with a
-- NULL control is invisible to both".
--
-- So a control can look empty to the picker while its practices are
-- perfectly reachable by (a). Rows below where LinkTableRows is 0 but
-- DirectFkRequirements is not are exactly that case, and 283 is the
-- migration written to repair it (dry run by default).
SELECT oc.organization_control_id AS OrganizationControlId,
       oc.control_code            AS ControlCode,
       -- (a) requirements pointing here by the direct FK
       (SELECT COUNT(*) FROM grac_practice.organization_requirement r
         WHERE r.organization_control_id = oc.organization_control_id
           AND r.status = N'Active')                       AS DirectFkRequirements,
       -- (b) what the picker actually reads
       (SELECT COUNT(*) FROM grac_practice.organization_control_requirement ocr
         WHERE ocr.organization_control_id = oc.organization_control_id
           AND ocr.status = N'Active')                     AS LinkTableRows,
       -- practices reachable by (a) but invisible to the picker
       (SELECT COUNT(DISTINCT p.practice_id)
          FROM grac_practice.organization_requirement r
          JOIN grac_practice.practice p
            ON p.organization_requirement_id = r.organization_requirement_id
           AND p.organization_id = @OrganizationId
           AND p.status = N'Active'
         WHERE r.organization_control_id = oc.organization_control_id
           AND r.status = N'Active')                       AS PracticesViaDirectFk,
       CASE
         WHEN (SELECT COUNT(*) FROM grac_practice.organization_control_requirement ocr
                WHERE ocr.organization_control_id = oc.organization_control_id
                  AND ocr.status = N'Active') = 0
          AND (SELECT COUNT(DISTINCT p.practice_id)
                 FROM grac_practice.organization_requirement r
                 JOIN grac_practice.practice p
                   ON p.organization_requirement_id = r.organization_requirement_id
                  AND p.organization_id = @OrganizationId
                  AND p.status = N'Active'
                WHERE r.organization_control_id = oc.organization_control_id
                  AND r.status = N'Active') > 0
              THEN '*** RUN 283 -- practices exist here but the 057 link row is missing'
         ELSE 'link table agrees with the direct FK'
       END                                                  AS Verdict
  FROM grac_practice.organization_control oc
 WHERE oc.organization_id = @OrganizationId
   AND oc.status = N'Active'
 ORDER BY Verdict DESC, oc.control_code;

PRINT '';
PRINT '--- and the root cause 283 repairs: requirements with NO control ---';
SELECT COUNT(*) AS ActiveRequirements,
       SUM(CASE WHEN organization_control_id IS NULL THEN 1 ELSE 0 END) AS WithNullControlId,
       CASE WHEN SUM(CASE WHEN organization_control_id IS NULL THEN 1 ELSE 0 END) > 0
            THEN '*** RUN 283 (DryRun = 1 first) -- these are invisible to the picker'
            ELSE 'every active requirement has a control' END AS Verdict
  FROM grac_practice.organization_requirement
 WHERE organization_id = @OrganizationId
   AND status = N'Active';

PRINT '';
PRINT 'Section 4 first. If it says RUN 283, that is the whole answer:';
PRINT '  database/283_backfill_requirement_control_id.sql';
PRINT '  It is DRY RUN by default -- read the plan, then set @DryRun = 0.';
PRINT '  It fixes organization_requirement.organization_control_id AND';
PRINT '  inserts the missing organization_control_requirement rows.';
PRINT '';
PRINT 'Section 1s Verdict column is the answer. The picker now LISTS a';
PRINT 'zero-practice control disabled and says "(no practices attached)"';
PRINT 'instead of hiding it, so this state is visible in the UI too.';
