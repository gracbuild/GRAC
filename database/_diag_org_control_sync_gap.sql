-- =====================================================================
-- _diag_org_control_sync_gap.sql
--
-- WHY THIS EXISTS
--   On UAT, grac_practice.organization_control has ZERO rows for this
--   organization on ANY release, even though the ISO 27001 repository
--   subscription itself exists (confirmed via sp_practice_picker_frameworks
--   returning 1 row). organization_control is supposed to be populated
--   two ways:
--     a) inline, by 002_practice_management_procedures.sql, the moment a
--        subscription is inserted/activated (entity_type =
--        'repository-subscriptions', and also the new-organization path)
--     b) by re-running 006_sync_organization_controls_from_subscriptions.sql,
--        a standalone backfill for subscriptions that existed BEFORE (a)
--        was added -- see 006's own header comment.
--
--   Both (a) and (b) need grac_new.source_control_map to have ACTIVE rows
--   for the subscription's release_id. If that repository catalog data
--   itself is missing on UAT for this release, running 006 will insert
--   nothing -- so this checks that BEFORE recommending 006.
--
--   This is READ-ONLY. Set @OrganizationName (or @OrganizationId) and run
--   the whole file; every section prints what it found.
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
-- 1. The subscription itself, full detail -- status fields exactly as
--    006 and the inline-sync branch of 002 test them
--    (status='Active' AND subscription_status='Active' AND release_id
--    IS NOT NULL). If any of those three is off, that alone explains
--    why nothing was ever synced -- no need to look further.
-- ---------------------------------------------------------------------
PRINT '';
PRINT '--- 1. repository_subscription rows for this organization ---';
SELECT s.subscription_id      AS SubscriptionId,
       s.release_id           AS ReleaseId,
       s.artifact_id          AS ArtifactId,
       s.authority_id         AS AuthorityId,
       s.subscription_type    AS SubscriptionType,
       s.status               AS Status,
       s.subscription_status  AS SubscriptionStatus,
       s.effective_dt         AS EffectiveDt,
       s.end_dt               AS EndDt,
       s.entered_by           AS EnteredBy,
       s.entered_dt           AS EnteredDt,
       CASE WHEN s.status = N'Active' AND ISNULL(s.subscription_status, N'Active') = N'Active' AND s.release_id IS NOT NULL
            THEN 'meets sync eligibility'
            ELSE 'does NOT meet sync eligibility -- this alone blocks 006' END AS SyncEligibility
FROM   grac_practice.repository_subscription s
WHERE  s.organization_id = @OrganizationId
ORDER BY s.subscription_id;

-- ---------------------------------------------------------------------
-- 2. The release/artifact/authority the subscription points at, so the
--    release_id can be read alongside its human name.
-- ---------------------------------------------------------------------
PRINT '';
PRINT '--- 2. Release / artifact / authority referenced by those subscriptions ---';
SELECT r.release_id     AS ReleaseId,
       r.version_no      AS ReleaseVersion,
       r.status           AS ReleaseStatus,
       a.artifact_id     AS ArtifactId,
       a.artifact_name   AS ArtifactName,
       au.authority_id   AS AuthorityId,
       au.authority_name AS AuthorityName
FROM   grac_practice.repository_subscription s
JOIN   grac_new.release r  ON r.release_id = s.release_id
LEFT JOIN grac_new.artifact a  ON a.artifact_id = r.artifact_id
LEFT JOIN grac_new.authority au ON au.authority_id = a.authority_id
WHERE  s.organization_id = @OrganizationId
GROUP BY r.release_id, r.version_no, r.status, a.artifact_id, a.artifact_name, au.authority_id, au.authority_name;

-- ---------------------------------------------------------------------
-- 3. THE key check: does grac_new.source_control_map -- the repository
--    catalog table both 006 and the inline-sync code read -- have ANY
--    active rows for this release at all on THIS database? If this is
--    0, 006 will insert nothing and the real gap is upstream, in the
--    repository content itself, not in organization_control.
-- ---------------------------------------------------------------------
PRINT '';
PRINT '--- 3. source_control_map rows available per subscribed release ---';
SELECT s.release_id                          AS ReleaseId,
       COUNT(DISTINCT scm.structure_node_id) AS StructureNodesLinked,
       COUNT(DISTINCT scm.control_id)        AS ControlsLinked,
       SUM(CASE WHEN scm.status = N'Active' THEN 1 ELSE 0 END) AS ActiveMapRows,
       COUNT(*)                              AS AllMapRowsAnyStatus
FROM   grac_practice.repository_subscription s
LEFT JOIN grac_new.source_structure_node n
       ON n.release_id = s.release_id AND n.status = N'Active'
LEFT JOIN grac_new.source_control_map scm
       ON scm.structure_node_id = n.structure_node_id
WHERE  s.organization_id = @OrganizationId
GROUP BY s.release_id;

-- ---------------------------------------------------------------------
-- 4. If section 3 shows zero ActiveMapRows, is that because there are
--    no structure nodes at all for this release, or nodes exist but
--    source_control_map simply never linked them to a control?
-- ---------------------------------------------------------------------
PRINT '';
PRINT '--- 4. source_structure_node rows per subscribed release (independent of the map) ---';
SELECT s.release_id                AS ReleaseId,
       COUNT(*)                    AS StructureNodeRows,
       SUM(CASE WHEN n.status = N'Active' THEN 1 ELSE 0 END) AS ActiveStructureNodeRows
FROM   grac_practice.repository_subscription s
LEFT JOIN grac_new.source_structure_node n ON n.release_id = s.release_id
WHERE  s.organization_id = @OrganizationId
GROUP BY s.release_id;

-- ---------------------------------------------------------------------
-- 5. Sanity check against a DIFFERENT organization on the same UAT
--    database that this diagnostic can compare to (any org with at
--    least one organization_control row for the SAME release_id). If
--    one exists, the release's catalog data is fine and the gap really
--    is isolated to this organization never having been synced.
-- ---------------------------------------------------------------------
PRINT '';
PRINT '--- 5. Any organization on this database with organization_control rows for the same release? ---';
SELECT oc.release_id                         AS ReleaseId,
       COUNT(DISTINCT oc.organization_id)    AS OrganizationsWithControls,
       COUNT(*)                              AS OrganizationControlRows
FROM   grac_practice.organization_control oc
WHERE  oc.release_id IN (SELECT DISTINCT release_id FROM grac_practice.repository_subscription WHERE organization_id = @OrganizationId)
GROUP BY oc.release_id;

PRINT '';
PRINT 'Read sections together:';
PRINT '  - Section 1 says SyncEligibility for every subscription row.';
PRINT '  - If section 1 is eligible but section 3 shows ActiveMapRows = 0,';
PRINT '    the repository catalog itself lacks this release''s control map';
PRINT '    on this database -- running 006 will not help; the fix is';
PRINT '    reloading/publishing that release''s content into grac_new.';
PRINT '  - If section 3 shows ActiveMapRows > 0, running';
PRINT '    006_sync_organization_controls_from_subscriptions.sql should';
PRINT '    populate organization_control for this organization.';
PRINT '  - Section 5 shows whether ANY organization on this database has';
PRINT '    been synced for this release -- if others have and this one';
PRINT '    has not, it strongly confirms an org-specific sync gap.';
GO
