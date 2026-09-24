-- =====================================================================
-- _diag_351_uat_end_to_end  (read-only, UAT)
--
-- Follow-up to _diag_351_uat_adoption_check.sql. That script's own
-- release-lookup was wrong (matched by artifact name + "highest
-- version_no", which landed on release_id=3 -- nobody subscribed).
-- Section 3's unfiltered cross-check found the real, populated release:
-- release_id=1, with 92 active organization_framework_statements each
-- for org 2 (Demo Bank) and org 3 (Soffit Infrastructure Services P Ltd).
--
-- This script:
--   Section 1 -- confirms subscription rows exist for org 2/3 + release 1
--               (if they do not, the picker's FRAMEWORK level -- which
--               reads repository_subscription -- will still show nothing
--               for these orgs even though the statement data is there).
--   Section 2 -- the three adoption counts (statements / requirements /
--               practices) for org 2 and org 3 under release_id=1.
--   Section 3 -- ACTUALLY CALLS the four picker procedures in sequence
--               for org 3 (Soffit -- your own org's UAT record, most
--               useful to see) + release_id=1, the same way the web UI
--               would: Structures -> first node's Controls -> first
--               control-or-statement's Practices. Real rows or real
--               "empty" at each step, not a proxy count.
--
-- Nothing here writes anything. Run as-is on UAT and paste back
-- everything it prints/returns.
-- =====================================================================
SET NOCOUNT ON;

DECLARE @release_id BIGINT = 1;

-- ---------------------------------------------------------------------
-- Section 1: subscription rows for org 2 / org 3 + release 1.
-- ---------------------------------------------------------------------
SELECT '1. Subscription rows, org 2/3, release 1' AS Step_,
       o.organization_id, o.organization_name,
       s.subscription_id, s.status AS SubscriptionStatus, s.subscription_status
FROM   grac_practice.organization o
LEFT JOIN grac_practice.repository_subscription s
       ON s.organization_id = o.organization_id AND s.release_id = @release_id
WHERE  o.organization_id IN (2, 3)
ORDER BY o.organization_id;

-- ---------------------------------------------------------------------
-- Section 2: the three adoption counts, org 2 and org 3, release 1.
-- ---------------------------------------------------------------------
SELECT '2. Adoption depth, org 2/3, release 1' AS Step_,
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
FROM   grac_practice.organization o
WHERE  o.organization_id IN (2, 3);

-- ---------------------------------------------------------------------
-- Section 3: exercise the picker end-to-end for org 3 + release 1,
-- exactly the way the web UI would call it.
-- ---------------------------------------------------------------------
DECLARE @organization_id BIGINT = 3;   -- Soffit Infrastructure Services P Ltd

PRINT '3a. sp_practice_picker_structures (org 3, release 1)';
DECLARE @structures TABLE(
    StructureNodeId BIGINT, ParentNodeId BIGINT, NodeLevel INT,
    NodeReference NVARCHAR(100), NodeTitle NVARCHAR(500),
    StructureName NVARCHAR(500), ControlCount INT);
INSERT INTO @structures
EXEC grac_practice.sp_practice_picker_structures @organization_id = @organization_id, @release_id = @release_id;
SELECT * FROM @structures ORDER BY StructureNodeId;

DECLARE @first_node BIGINT = (SELECT TOP 1 StructureNodeId FROM @structures WHERE ControlCount > 0 ORDER BY StructureNodeId);
IF @first_node IS NULL SET @first_node = (SELECT TOP 1 StructureNodeId FROM @structures ORDER BY StructureNodeId);

PRINT '3b. sp_practice_picker_controls for the first structure node found above';
SELECT @first_node AS StructureNodeIdUsed;
DECLARE @controls TABLE(
    OrganizationControlId BIGINT, ControlCode NVARCHAR(200), ControlName NVARCHAR(500),
    ApplicabilityStatus NVARCHAR(100), PracticeCount INT);
IF @first_node IS NOT NULL
BEGIN
    INSERT INTO @controls
    EXEC grac_practice.sp_practice_picker_controls @organization_id = @organization_id, @release_id = @release_id, @structure_node_id = @first_node;
END
SELECT * FROM @controls ORDER BY ControlCode;

DECLARE @first_control BIGINT = (SELECT TOP 1 OrganizationControlId FROM @controls WHERE PracticeCount > 0 ORDER BY OrganizationControlId);
IF @first_control IS NULL SET @first_control = (SELECT TOP 1 OrganizationControlId FROM @controls ORDER BY OrganizationControlId);

PRINT '3c. sp_practice_picker_practices for the first control/statement found above (negative id = Statement, positive = Control)';
SELECT @first_control AS OrganizationControlIdUsed;
DECLARE @practices TABLE(
    PracticeId BIGINT, PracticeCode NVARCHAR(200), PracticeName NVARCHAR(500),
    ApplicabilityStatus NVARCHAR(100), OrganizationRequirementId BIGINT,
    OrganizationControlId BIGINT, ControlCode NVARCHAR(200),
    AlreadyMappedToRisk BIT, MapSourceCode NVARCHAR(100));
IF @first_control IS NOT NULL
BEGIN
    INSERT INTO @practices
    EXEC grac_practice.sp_practice_picker_practices @organization_id = @organization_id, @organization_control_id = @first_control;
END
SELECT * FROM @practices ORDER BY PracticeCode;

PRINT '';
PRINT 'Read 3a/3b/3c top to bottom: each should hand a real id to the next';
PRINT 'step, same as clicking through the picker in the browser. If 3a is';
PRINT 'empty, the FRAMEWORK/subscription level (Section 1 above) is the';
PRINT 'place to look, not the picker fix itself.';
