-- =====================================================================
-- _diag_351_uat_adoption_check  (read-only, UAT)
--
-- 351's own verification block hard-coded a lookup for an org named
-- "YogLoans" for its adoption-check section. That org does not exist on
-- UAT (OrganizationId came back NULL, so the 0/0 ActiveOrgFrameworkStatements
-- / ActiveOrgRequirementsViaStatement counts that followed are meaningless
-- -- they were counted against nothing). This script finds the org(s)
-- that actually matter on UAT and checks the same two numbers for each.
--
-- Section 1: which organization(s) are subscribed to the ISO 27001 2022
--            release on UAT at all.
-- Section 2: for each of those orgs, does it have any new-model
--            (Statement/Requirement) adoption yet -- the same two counts
--            351's own script tried to report, against the right org
--            this time.
-- Section 3: as a cross-check, the same two counts for EVERY org that
--            has ANY organization_framework_statements or
--            org_statement_id-linked requirement at all, regardless of
--            release -- in case ISO 27001 adoption exists under a
--            different release_id than expected, or subscription rows
--            are themselves missing/inactive.
--
-- Nothing here writes anything. Run as-is on UAT and paste back all
-- three result sets.
-- =====================================================================
SET NOCOUNT ON;

DECLARE @release_id BIGINT = (
    SELECT TOP 1 r.release_id
    FROM   grac_new.release r
    JOIN   grac_new.artifact a ON a.artifact_id = r.artifact_id
    WHERE  a.artifact_name LIKE N'%ISO%27001%' OR a.artifact_code LIKE N'%27001%'
    ORDER BY r.version_no DESC
);

SELECT '0. Resolved ISO 27001 release_id' AS Step_, @release_id AS ReleaseId;

-- ---------------------------------------------------------------------
-- Section 1: organizations subscribed to this release on UAT.
-- ---------------------------------------------------------------------
SELECT '1. Orgs subscribed to the ISO 27001 release' AS Step_,
       o.organization_id, o.organization_name,
       s.subscription_id, s.status AS SubscriptionStatus,
       s.subscription_status
FROM   grac_practice.repository_subscription s
JOIN   grac_practice.organization o ON o.organization_id = s.organization_id
WHERE  s.release_id = @release_id
ORDER BY o.organization_name;

-- ---------------------------------------------------------------------
-- Section 2: new-model adoption, per org subscribed to this release.
-- ---------------------------------------------------------------------
SELECT '2. New-model adoption per subscribed org' AS Step_,
       o.organization_id, o.organization_name,
       (SELECT COUNT(*) FROM grac_practice.organization_framework_statements ofs
         WHERE ofs.organization_id = o.organization_id
           AND ofs.release_id = @release_id
           AND ofs.status = N'Active')                              AS ActiveOrgFrameworkStatements,
       (SELECT COUNT(*) FROM grac_practice.organization_requirement q
         WHERE q.organization_id = o.organization_id
           AND q.org_statement_id IS NOT NULL
           AND q.status = N'Active'
           AND EXISTS (SELECT 1 FROM grac_practice.organization_framework_statements ofs2
                        WHERE ofs2.org_statement_id = q.org_statement_id
                          AND ofs2.release_id = @release_id))        AS ActiveOrgRequirementsViaStatement,
       (SELECT COUNT(*) FROM grac_practice.practice p
         JOIN grac_practice.organization_requirement q2 ON q2.organization_requirement_id = p.organization_requirement_id
         WHERE p.organization_id = o.organization_id
           AND q2.org_statement_id IS NOT NULL
           AND p.status = N'Active'
           AND EXISTS (SELECT 1 FROM grac_practice.organization_framework_statements ofs3
                        WHERE ofs3.org_statement_id = q2.org_statement_id
                          AND ofs3.release_id = @release_id))        AS ActivePracticesViaStatement
FROM   grac_practice.repository_subscription s
JOIN   grac_practice.organization o ON o.organization_id = s.organization_id
WHERE  s.release_id = @release_id
GROUP BY o.organization_id, o.organization_name
ORDER BY o.organization_name;

-- ---------------------------------------------------------------------
-- Section 3: cross-check -- ANY org with new-model adoption at all,
-- regardless of release (in case it is filed under a release_id other
-- than the one Section 0 resolved, or the subscription row itself is
-- missing/inactive so Section 1 shows nothing).
-- ---------------------------------------------------------------------
SELECT '3. Any org with new-model adoption, any release' AS Step_,
       o.organization_id, o.organization_name,
       ofs.release_id,
       COUNT(DISTINCT ofs.org_statement_id) AS ActiveOrgFrameworkStatements
FROM   grac_practice.organization_framework_statements ofs
JOIN   grac_practice.organization o ON o.organization_id = ofs.organization_id
WHERE  ofs.status = N'Active'
GROUP BY o.organization_id, o.organization_name, ofs.release_id
ORDER BY o.organization_name, ofs.release_id;
