-- =====================================================================
-- _diag_iso27001_release_mismatch_check.sql
--
-- WHY THIS EXISTS
--   The prior diagnostic found release_id = 1 (the release this
--   organization's subscription points to) has only 7 source_structure_node
--   rows (just the Annex A / 5 / 6 / 7 / 8 category headers) and ZERO
--   source_control_map rows.
--
--   But the Control Management admin screen's "Source Statements" list
--   (Repository Management > Source Statements, filtered to "All
--   releases") shows 94 records for ISO 27001, with granular references
--   like 5.1, 5.2, 5.3 -- i.e. real content clearly exists SOMEWHERE in
--   this database for ISO 27001. Since that screen was showing "All
--   releases" (not filtered to release_id 1 specifically), the most
--   likely explanation is a RELEASE MISMATCH: the real, fully-populated
--   ISO 27001:2022 content lives under a DIFFERENT release_id than the
--   one (1) this organization's subscription is bound to -- e.g. a
--   duplicate/stub release row was created and the org got subscribed to
--   the wrong one.
--
--   This is READ-ONLY. It lists every release_id that looks like ISO
--   27001 on this database, with a content count for each, so we can see
--   at a glance whether release_id 1 is the odd one out.
-- =====================================================================
SET NOCOUNT ON;

PRINT '--- 1. Every release that looks like ISO 27001 on this database ---';
SELECT r.release_id     AS ReleaseId,
       r.version_no      AS ReleaseVersion,
       r.status           AS ReleaseStatus,
       a.artifact_id     AS ArtifactId,
       a.artifact_name   AS ArtifactName,
       au.authority_id   AS AuthorityId,
       au.authority_name AS AuthorityName
FROM   grac_new.release r
LEFT JOIN grac_new.artifact a   ON a.artifact_id = r.artifact_id
LEFT JOIN grac_new.authority au ON au.authority_id = a.authority_id
WHERE  a.artifact_name LIKE N'%Information Security%'
   OR  au.authority_name LIKE N'%Standardization%'
   OR  r.version_no LIKE N'%2022%'
ORDER BY r.release_id;

-- ---------------------------------------------------------------------
-- 2. For every release_id found above, how much content actually sits
--    under it -- structure nodes, framework statements, and active
--    control-map rows. The release_id with real numbers here is the
--    one that should be subscribed to.
-- ---------------------------------------------------------------------
PRINT '';
PRINT '--- 2. Content counts per candidate release_id ---';
;WITH candidate_releases AS (
    SELECT DISTINCT r.release_id
    FROM   grac_new.release r
    LEFT JOIN grac_new.artifact a   ON a.artifact_id = r.artifact_id
    LEFT JOIN grac_new.authority au ON au.authority_id = a.authority_id
    WHERE  a.artifact_name LIKE N'%Information Security%'
       OR  au.authority_name LIKE N'%Standardization%'
       OR  r.version_no LIKE N'%2022%'
)
SELECT cr.release_id                                            AS ReleaseId,
       (SELECT COUNT(*) FROM grac_new.source_structure_node n
         WHERE n.release_id = cr.release_id)                    AS StructureNodeRows,
       (SELECT COUNT(*) FROM grac_new.source_structure_node n
         WHERE n.release_id = cr.release_id AND n.status = N'Active') AS ActiveStructureNodeRows,
       (SELECT COUNT(*) FROM grac_new.framework_statement fs
         WHERE fs.release_id = cr.release_id)                   AS FrameworkStatementRows,
       (SELECT COUNT(*)
          FROM grac_new.source_control_map scm
          JOIN grac_new.source_structure_node n2 ON n2.structure_node_id = scm.structure_node_id
         WHERE n2.release_id = cr.release_id AND scm.status = N'Active') AS ActiveControlMapRows,
       (SELECT COUNT(DISTINCT s.organization_id) FROM grac_practice.repository_subscription s
         WHERE s.release_id = cr.release_id AND s.status = N'Active') AS OrgsSubscribedToThisRelease
FROM   candidate_releases cr
ORDER BY cr.release_id;

PRINT '';
PRINT 'Compare ReleaseId = 1 (this organization''s current subscription)';
PRINT 'against any other release_id shown above. If another release_id';
PRINT 'has the real StructureNodeRows / FrameworkStatementRows /';
PRINT 'ActiveControlMapRows counts (matching the 94 seen on screen) and';
PRINT 'release_id 1 does not, the fix is re-pointing the subscription at';
PRINT 'the correct release_id -- not reloading any content.';
GO
