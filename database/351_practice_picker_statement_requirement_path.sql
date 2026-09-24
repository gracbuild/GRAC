-- =====================================================================
-- 351 Practice Picker -- add the Statement/Requirement path
--
-- BACKGROUND (confirmed with the product owner)
--   The repository model changed. The ORIGINAL design reduced every
--   Source Statement down to a unique "Control", and Controls were what
--   got mapped to a release's structure (grac_new.source_control_map).
--   That design has been superseded: Source Statements are now captured
--   and kept as-is, per release, with no Control-reduction step. The
--   "unique value" that used to be a Control is now a Requirement
--   (grac_new.requirement / grac_practice.organization_requirement),
--   linked directly to its Source Statement -- not to a structure node
--   via source_control_map at all.
--
--   Migration 011 (2025, "Practice Management repository alignment")
--   already declared this as the final model:
--     Framework Statement <-> Requirement
--     Requirement -> Practice / Practice Instance
--   and added organization_requirement.org_statement_id plus
--   grac_practice.organization_framework_statements for exactly this
--   purpose. ControlManagement's own "Practices - Statement Mapping"
--   screen (entity key source-control-mappings, database/002, the
--   @p_entity_type='source-control-mappings' SELECT) already queries
--   this new path and even aliases grac_new.requirement as BOTH
--   ControlCode/ControlName and PracticeCode/PracticeName -- proof this
--   is the intended, working replacement, not a guess on our part.
--
--   The Practice Picker (sp_practice_picker_structures/_controls/
--   _practices/_resolve, migration 282, extended by 312 and 349) was
--   built entirely on the OLD path: structure node -> source_control_map
--   -> organization_control. It never learned about the new path, so any
--   release loaded the new way (confirmed for ISO 27001 on UAT: 7
--   structure nodes, 93 correctly-loaded framework_statement rows, ZERO
--   source_control_map rows -- by design, not by accident) shows an
--   empty picker no matter what data exists, while a release still
--   carrying real Controls (PCI-DSS on dev) keeps working.
--
-- THE FIX -- ADD THE NEW PATH ALONGSIDE THE OLD ONE
--   Per the agreed direction: do not retire the Controls path (PCI-DSS on
--   dev still depends on it), add the Statement/Requirement path beside
--   it. Every one of the four procedures below now UNIONs both paths, so
--   the Control step in the UI shows whichever kind of item a given
--   release actually has -- real Controls, Statements, or (in principle)
--   both at once.
--
--   The org-level anchor for the new path is organization_requirement.
--   org_statement_id (route 2 style, added by 011) -- NOT
--   framework_statement_requirement_map. The map table is a repository
--   catalog suggestion (route 1 style: "this requirement COULD belong to
--   this statement"), exactly like control_requirement_map was for the
--   old model, and 283/350 already established that route 2 (what the
--   organization's own requirement actually points at) outranks route 1
--   when the two disagree. The picker only needs to show practices the
--   organization already has, so org_statement_id alone is sufficient
--   and authoritative; the map table is not read here.
--
-- HOW A "STATEMENT" ITEM IS IDENTIFIED
--   The picker's Control step (LEVEL 3) returns an OrganizationControlId
--   the caller round-trips to LEVEL 4. There is no organization-level row
--   for a Statement to reuse that column honestly, so a Statement item is
--   identified by -framework_statement_id (always negative -- a real
--   organization_control_id is a positive IDENTITY value, so the two
--   spaces can never collide). This is the same sentinel convention 282
--   already uses for the ORG-PRACTICES structure node (-1). LEVEL 4
--   branches on the sign of @organization_control_id; nothing about its
--   parameter list, or what any caller persists, changes -- confirmed
--   again by re-reading risk-centre.js and exception-centre.js, which
--   still only ever post { practiceId }.
--
-- WHAT THIS DOES NOT DO
--   It does not create organization_framework_statements or
--   organization_requirement rows for any organization. If an
--   organization has never had a Statement marked applicable or a
--   Practice created against it under ISO 27001 (or any other new-model
--   release), the picker will correctly show nothing for that org+
--   release, same as it correctly shows nothing today for an org with no
--   organization_control rows. That is Governance/data work, not
--   something a picker query can conjure. Section 3 of the verification
--   block below reports whether the organization used in earlier
--   diagnostics already has any such rows, so this is not left to guess.
--
-- Re-runnable: yes (CREATE OR ALTER).
-- Rollback:   database/351_practice_picker_statement_requirement_path_rollback.sql
--             (restores the exact procedure bodies 349 left in place)
-- DEPENDS ON: 282 (base procedures), 312 (risk-scope params on LEVEL 4),
--             349 (direct-FK-or-057 match on the OLD path, preserved
--             byte-for-byte here), 011 (organization_framework_statements,
--             organization_requirement.org_statement_id).
-- ASCII-only on purpose (sqlcmd codepage safety).
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

DECLARE @prereqs_ok BIT = 1;

IF OBJECT_ID('grac_practice.sp_practice_picker_controls','P') IS NULL
   OR OBJECT_ID('grac_practice.sp_practice_picker_practices','P') IS NULL
   OR OBJECT_ID('grac_practice.sp_practice_picker_structures','P') IS NULL
   OR OBJECT_ID('grac_practice.sp_practice_picker_resolve','P') IS NULL
BEGIN
    PRINT 'ABORT (351): one or more sp_practice_picker_* procedures missing. Run 282, 312, 349 first.';
    SET @prereqs_ok = 0;
END

IF OBJECT_ID('grac_practice.organization_framework_statements','U') IS NULL
BEGIN
    PRINT 'ABORT (351): organization_framework_statements missing. Run 011 first.';
    SET @prereqs_ok = 0;
END

IF COL_LENGTH('grac_practice.organization_requirement','org_statement_id') IS NULL
BEGIN
    PRINT 'ABORT (351): organization_requirement.org_statement_id missing. Run 011 first.';
    SET @prereqs_ok = 0;
END

IF OBJECT_ID('grac_new.framework_statement','U') IS NULL
BEGIN
    PRINT 'ABORT (351): grac_new.framework_statement missing. Run the ControlManagement repository schema first.';
    SET @prereqs_ok = 0;
END

IF @prereqs_ok = 0
BEGIN
    RAISERROR('351_practice_picker_statement_requirement_path: prerequisites missing -- see PRINT messages above. Nothing was changed.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- LEVEL 2 -- Source structures within one framework release.
--   ControlCount now counts items reachable by EITHER path, so a node
--   whose only content is Statements (no source_control_map rows at all)
--   still appears instead of vanishing the whole branch.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_practice_picker_structures
    @organization_id BIGINT,
    @release_id      BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL OR @release_id IS NULL
        THROW 57002, 'sp_practice_picker_structures: organization_id and release_id are required.', 1;

    -- Sentinel release: unchanged from 282.
    IF @release_id = -1
    BEGIN
        SELECT CAST(-1 AS BIGINT)   AS StructureNodeId,
               CAST(NULL AS BIGINT) AS ParentNodeId,
               1                    AS NodeLevel,
               CAST(NULL AS NVARCHAR(100)) AS NodeReference,
               N'Organization Defined Practices' AS NodeTitle,
               N'Organization Defined Practices' AS StructureName,
               COUNT(DISTINCT oc.organization_control_id) AS ControlCount
        FROM   grac_practice.organization_control oc
        WHERE  oc.organization_id = @organization_id
          AND  oc.control_code = N'ORG-PRACTICES'
          AND  oc.origin_type  = N'Organization'
          AND  oc.status = N'Active';
        RETURN;
    END

    ;WITH reachable_items AS (
        -- OLD model: structure node -> source_control_map -> organization_control.
        -- Unchanged from 282.
        SELECT n.structure_node_id AS StructureNodeId,
               oc.organization_control_id AS ItemId
        FROM   grac_new.source_structure_node n
        JOIN   grac_new.source_control_map scm
               ON scm.structure_node_id = n.structure_node_id
              AND scm.status = N'Active'
        JOIN   grac_practice.organization_control oc
               ON oc.repository_control_id = scm.control_id
              AND oc.organization_id       = @organization_id
              AND oc.release_id            = @release_id
              AND oc.status                = N'Active'
        WHERE  n.release_id = @release_id
          AND  n.status     = N'Active'

        UNION ALL

        -- NEW model: structure node -> framework_statement -> the
        -- organization's own statement adoption. A statement this
        -- organization has in scope for this release is a picker item
        -- even with zero practices under it yet, mirroring how an
        -- adopted-but-empty organization_control still counts above.
        SELECT fs.structure_node_id AS StructureNodeId,
               -fs.framework_statement_id AS ItemId
        FROM   grac_new.framework_statement fs
        JOIN   grac_new.source_structure_node n
               ON n.structure_node_id = fs.structure_node_id
              AND n.release_id        = @release_id
              AND n.status            = N'Active'
        JOIN   grac_practice.organization_framework_statements ofs
               ON ofs.framework_statement_id = fs.framework_statement_id
              AND ofs.organization_id        = @organization_id
              AND ofs.release_id             = @release_id
              AND ofs.status                 = N'Active'
        WHERE  fs.release_id = @release_id
          AND  fs.status     = N'Active'
    )
    SELECT n.structure_node_id                       AS StructureNodeId,
           n.parent_node_id                          AS ParentNodeId,
           n.node_level                              AS NodeLevel,
           n.node_reference                          AS NodeReference,
           n.node_title                              AS NodeTitle,
           COALESCE(NULLIF(n.node_reference, N'') + N' - ', N'')
               + n.node_title                        AS StructureName,
           COUNT(DISTINCT ri.ItemId)                 AS ControlCount
    FROM   grac_new.source_structure_node n
    JOIN   reachable_items ri ON ri.StructureNodeId = n.structure_node_id
    WHERE  n.release_id = @release_id
      AND  n.status     = N'Active'
    GROUP BY n.structure_node_id, n.parent_node_id, n.node_level,
             n.node_reference, n.node_title, n.display_order
    ORDER BY n.display_order, n.node_reference, n.node_title;
END
GO

-- =====================================================================
-- LEVEL 3 -- Controls (or Statements) under one source structure node.
--   OLD-model rows: unchanged from 349, verbatim (direct FK or 057 link
--   table match). NEW-model rows: one per Statement this organization
--   has adopted under this node, identified by -framework_statement_id.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_practice_picker_controls
    @organization_id   BIGINT,
    @release_id        BIGINT,
    @structure_node_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL OR @structure_node_id IS NULL
        THROW 57003, 'sp_practice_picker_controls: organization_id and structure_node_id are required.', 1;

    -- ORG-PRACTICES sentinel: unchanged from 349 (no new-model
    -- equivalent -- manually added practices have no framework at all).
    IF @structure_node_id = -1
    BEGIN
        SELECT oc.organization_control_id  AS OrganizationControlId,
               oc.control_code             AS ControlCode,
               oc.control_name             AS ControlName,
               oc.applicability_status     AS ApplicabilityStatus,
               COUNT(DISTINCT p.practice_id) AS PracticeCount
        FROM   grac_practice.organization_control oc
        LEFT JOIN grac_practice.organization_requirement q
               ON q.status = N'Active'
              AND (
                    q.organization_control_id = oc.organization_control_id
                    OR EXISTS (
                        SELECT 1
                        FROM   grac_practice.organization_control_requirement ocr
                        WHERE  ocr.organization_control_id     = oc.organization_control_id
                          AND  ocr.organization_requirement_id = q.organization_requirement_id
                          AND  ocr.status = N'Active'
                    )
              )
        LEFT JOIN grac_practice.practice p
               ON p.organization_requirement_id = q.organization_requirement_id
              AND p.organization_id = @organization_id
              AND p.status = N'Active'
        WHERE  oc.organization_id = @organization_id
          AND  oc.control_code = N'ORG-PRACTICES'
          AND  oc.origin_type  = N'Organization'
          AND  oc.status = N'Active'
        GROUP BY oc.organization_control_id, oc.control_code,
                 oc.control_name, oc.applicability_status;
        RETURN;
    END

    -- OLD model: verbatim from 349.
    SELECT oc.organization_control_id                AS OrganizationControlId,
           oc.control_code                           AS ControlCode,
           oc.control_name                           AS ControlName,
           oc.applicability_status                   AS ApplicabilityStatus,
           COUNT(DISTINCT p.practice_id)             AS PracticeCount
    FROM   grac_new.source_control_map scm
    JOIN   grac_practice.organization_control oc
           ON oc.repository_control_id = scm.control_id
          AND oc.organization_id       = @organization_id
          AND oc.status                = N'Active'
          AND (@release_id IS NULL OR oc.release_id = @release_id)
    LEFT JOIN grac_practice.organization_requirement q
           ON q.status = N'Active'
          AND (
                q.organization_control_id = oc.organization_control_id
                OR EXISTS (
                    SELECT 1
                    FROM   grac_practice.organization_control_requirement ocr
                    WHERE  ocr.organization_control_id     = oc.organization_control_id
                      AND  ocr.organization_requirement_id = q.organization_requirement_id
                      AND  ocr.status = N'Active'
                )
          )
    LEFT JOIN grac_practice.practice p
           ON p.organization_requirement_id = q.organization_requirement_id
          AND p.organization_id = @organization_id
          AND p.status = N'Active'
    WHERE  scm.structure_node_id = @structure_node_id
      AND  scm.status = N'Active'
    GROUP BY oc.organization_control_id, oc.control_code,
             oc.control_name, oc.applicability_status

    UNION ALL

    -- NEW model: Statements this organization has adopted under this
    -- node, shown as control-equivalent items. PracticeCount reached via
    -- organization_requirement.org_statement_id (route 2 -- the org's
    -- own assignment), never framework_statement_requirement_map (route
    -- 1 -- a repository suggestion only).
    SELECT -fs.framework_statement_id                AS OrganizationControlId,
           fs.statement_reference                    AS ControlCode,
           fs.statement_title                        AS ControlName,
           aps.status_name                           AS ApplicabilityStatus,
           COUNT(DISTINCT p.practice_id)             AS PracticeCount
    FROM   grac_new.framework_statement fs
    JOIN   grac_practice.organization_framework_statements ofs
           ON ofs.framework_statement_id = fs.framework_statement_id
          AND ofs.organization_id        = @organization_id
          AND (@release_id IS NULL OR ofs.release_id = @release_id)
          AND ofs.status                 = N'Active'
    LEFT JOIN grac_practice.applicability_status_master aps
           ON aps.applicability_status_id = ofs.applicability_status_id
    LEFT JOIN grac_practice.organization_requirement q
           ON q.org_statement_id = ofs.org_statement_id
          AND q.organization_id  = @organization_id
          AND q.status = N'Active'
    LEFT JOIN grac_practice.practice p
           ON p.organization_requirement_id = q.organization_requirement_id
          AND p.organization_id = @organization_id
          AND p.status = N'Active'
    WHERE  fs.structure_node_id = @structure_node_id
      AND  fs.status = N'Active'
    GROUP BY fs.framework_statement_id, fs.statement_reference,
             fs.statement_title, aps.status_name

    ORDER BY ControlCode, ControlName;
END
GO

-- =====================================================================
-- LEVEL 4 -- Practices under one control (or statement).
--   A negative @organization_control_id means the caller is asking
--   about a Statement item from LEVEL 3's new-model branch above; a
--   positive one is a real organization_control_id, handled exactly as
--   349 left it (verbatim, including the risk-scope parameters from
--   312). Output columns are identical in both branches, so
--   PracticePickerService.cs and the JS picker need no changes.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_practice_picker_practices
    @organization_id         BIGINT,
    @organization_control_id BIGINT,
    @search                  NVARCHAR(200) = NULL,
    @exclude_practice_ids    NVARCHAR(MAX) = NULL,
    @risk_register_id        BIGINT        = NULL,
    @include_already_mapped  BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL OR @organization_control_id IS NULL
        THROW 57004, 'sp_practice_picker_practices: organization_id and organization_control_id are required.', 1;

    DECLARE @excluded TABLE(practice_id BIGINT PRIMARY KEY);
    IF @exclude_practice_ids IS NOT NULL AND LEN(LTRIM(RTRIM(@exclude_practice_ids))) > 0
        INSERT INTO @excluded(practice_id)
        SELECT DISTINCT TRY_CONVERT(BIGINT, LTRIM(RTRIM(value)))
        FROM   STRING_SPLIT(@exclude_practice_ids, ',')
        WHERE  TRY_CONVERT(BIGINT, LTRIM(RTRIM(value))) IS NOT NULL;

    IF @organization_control_id < 0
    BEGIN
        -- NEW model: @organization_control_id is -framework_statement_id.
        DECLARE @framework_statement_id BIGINT = -@organization_control_id;

        SELECT p.practice_id                        AS PracticeId,
               p.practice_code                      AS PracticeCode,
               p.practice_name                      AS PracticeName,
               p.applicability_status               AS ApplicabilityStatus,
               q.organization_requirement_id        AS OrganizationRequirementId,
               @organization_control_id             AS OrganizationControlId,
               fs.statement_reference               AS ControlCode,
               CAST(CASE WHEN @risk_register_id IS NOT NULL
                          AND EXISTS (SELECT 1
                                        FROM grac_practice.risk_practice_map pm
                                       WHERE pm.organization_id  = @organization_id
                                         AND pm.risk_register_id = @risk_register_id
                                         AND pm.practice_id      = p.practice_id)
                         THEN 1 ELSE 0 END AS BIT) AS AlreadyMappedToRisk,
               (SELECT TOP 1 pm2.map_source_code
                  FROM grac_practice.risk_practice_map pm2
                 WHERE pm2.organization_id  = @organization_id
                   AND pm2.risk_register_id = @risk_register_id
                   AND pm2.practice_id      = p.practice_id) AS MapSourceCode
        FROM   grac_new.framework_statement fs
        JOIN   grac_practice.organization_framework_statements ofs
               ON ofs.framework_statement_id = fs.framework_statement_id
              AND ofs.organization_id        = @organization_id
              AND ofs.status                 = N'Active'
        JOIN   grac_practice.organization_requirement q
               ON q.org_statement_id = ofs.org_statement_id
              AND q.organization_id  = @organization_id
              AND q.status = N'Active'
        JOIN   grac_practice.practice p
               ON p.organization_requirement_id = q.organization_requirement_id
              AND p.organization_id = @organization_id
              AND p.status = N'Active'
        WHERE  fs.framework_statement_id = @framework_statement_id
          AND  NOT EXISTS (SELECT 1 FROM @excluded x WHERE x.practice_id = p.practice_id)
          AND  (@risk_register_id IS NULL
                OR @include_already_mapped = 1
                OR NOT EXISTS (SELECT 1
                                 FROM grac_practice.risk_practice_map pm
                                WHERE pm.organization_id  = @organization_id
                                  AND pm.risk_register_id = @risk_register_id
                                  AND pm.practice_id      = p.practice_id))
          AND  (@search IS NULL OR LEN(LTRIM(RTRIM(@search))) = 0
                OR p.practice_name LIKE N'%' + @search + N'%'
                OR p.practice_code LIKE N'%' + @search + N'%')
        ORDER BY p.practice_code, p.practice_name;
        RETURN;
    END

    -- OLD model: verbatim from 349.
    SELECT p.practice_id                        AS PracticeId,
           p.practice_code                      AS PracticeCode,
           p.practice_name                      AS PracticeName,
           p.applicability_status               AS ApplicabilityStatus,
           q.organization_requirement_id        AS OrganizationRequirementId,
           oc.organization_control_id           AS OrganizationControlId,
           oc.control_code                      AS ControlCode,
           CAST(CASE WHEN @risk_register_id IS NOT NULL
                      AND EXISTS (SELECT 1
                                    FROM grac_practice.risk_practice_map pm
                                   WHERE pm.organization_id  = @organization_id
                                     AND pm.risk_register_id = @risk_register_id
                                     AND pm.practice_id      = p.practice_id)
                     THEN 1 ELSE 0 END AS BIT) AS AlreadyMappedToRisk,
           (SELECT TOP 1 pm2.map_source_code
              FROM grac_practice.risk_practice_map pm2
             WHERE pm2.organization_id  = @organization_id
               AND pm2.risk_register_id = @risk_register_id
               AND pm2.practice_id      = p.practice_id) AS MapSourceCode
    FROM   grac_practice.organization_control oc
    JOIN   grac_practice.organization_requirement q
           ON q.status = N'Active'
          AND (
                q.organization_control_id = oc.organization_control_id
                OR EXISTS (
                    SELECT 1
                    FROM   grac_practice.organization_control_requirement ocr
                    WHERE  ocr.organization_control_id     = oc.organization_control_id
                      AND  ocr.organization_requirement_id = q.organization_requirement_id
                      AND  ocr.status = N'Active'
                )
          )
    JOIN   grac_practice.practice p
           ON p.organization_requirement_id = q.organization_requirement_id
          AND p.organization_id = @organization_id
          AND p.status = N'Active'
    WHERE  oc.organization_control_id = @organization_control_id
      AND  oc.organization_id = @organization_id
      AND  oc.status = N'Active'
      AND  NOT EXISTS (SELECT 1 FROM @excluded x WHERE x.practice_id = p.practice_id)
      AND  (@risk_register_id IS NULL
            OR @include_already_mapped = 1
            OR NOT EXISTS (SELECT 1
                             FROM grac_practice.risk_practice_map pm
                            WHERE pm.organization_id  = @organization_id
                              AND pm.risk_register_id = @risk_register_id
                              AND pm.practice_id      = p.practice_id))
      AND  (@search IS NULL OR LEN(LTRIM(RTRIM(@search))) = 0
            OR p.practice_name LIKE N'%' + @search + N'%'
            OR p.practice_code LIKE N'%' + @search + N'%')
    ORDER BY p.practice_code, p.practice_name;
END
GO

-- =====================================================================
-- EDIT MODE -- resolve a practice back up to its full hierarchy.
--   Tries both paths and returns one defensible row, preferring the OLD
--   (Control) path when a practice is somehow reachable by both.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_practice_picker_resolve
    @organization_id BIGINT,
    @practice_id     BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL OR @practice_id IS NULL
        THROW 57005, 'sp_practice_picker_resolve: organization_id and practice_id are required.', 1;

    ;WITH old_path AS (
        SELECT p.practice_id                  AS PracticeId,
               p.practice_code                AS PracticeCode,
               p.practice_name                AS PracticeName,
               oc.organization_control_id     AS OrganizationControlId,
               oc.control_code                AS ControlCode,
               oc.control_name                AS ControlName,
               n.structure_node_id            AS StructureNodeId,
               n.node_title                   AS NodeTitle,
               COALESCE(NULLIF(n.node_reference, N'') + N' - ', N'')
                   + n.node_title             AS StructureName,
               oc.release_id                  AS ReleaseId,
               COALESCE(a.artifact_code + N' ' + r.version_no,
                        a.artifact_name + N' ' + r.version_no,
                        r.version_no)         AS FrameworkName,
               0                              AS SourcePrecedence
        FROM   grac_practice.practice p
        JOIN   grac_practice.organization_requirement q
               ON q.organization_requirement_id = p.organization_requirement_id
        JOIN   grac_practice.organization_control_requirement ocr
               ON ocr.organization_requirement_id = q.organization_requirement_id
              AND ocr.status = N'Active'
        JOIN   grac_practice.organization_control oc
               ON oc.organization_control_id = ocr.organization_control_id
              AND oc.organization_id = @organization_id
              AND oc.status = N'Active'
        LEFT JOIN grac_new.source_control_map scm
               ON scm.control_id = oc.repository_control_id
              AND scm.status = N'Active'
        LEFT JOIN grac_new.source_structure_node n
               ON n.structure_node_id = scm.structure_node_id
              AND n.release_id = oc.release_id
              AND n.status = N'Active'
        LEFT JOIN grac_new.release r  ON r.release_id  = oc.release_id
        LEFT JOIN grac_new.artifact a ON a.artifact_id = COALESCE(oc.artifact_id, r.artifact_id)
        WHERE  p.practice_id = @practice_id
          AND  p.organization_id = @organization_id
          AND  p.status = N'Active'
    ),
    new_path AS (
        SELECT p.practice_id                  AS PracticeId,
               p.practice_code                AS PracticeCode,
               p.practice_name                AS PracticeName,
               -fs.framework_statement_id     AS OrganizationControlId,
               fs.statement_reference         AS ControlCode,
               fs.statement_title             AS ControlName,
               n.structure_node_id            AS StructureNodeId,
               n.node_title                   AS NodeTitle,
               COALESCE(NULLIF(n.node_reference, N'') + N' - ', N'')
                   + n.node_title             AS StructureName,
               ofs.release_id                 AS ReleaseId,
               COALESCE(a.artifact_code + N' ' + r.version_no,
                        a.artifact_name + N' ' + r.version_no,
                        r.version_no)         AS FrameworkName,
               1                              AS SourcePrecedence
        FROM   grac_practice.practice p
        JOIN   grac_practice.organization_requirement q
               ON q.organization_requirement_id = p.organization_requirement_id
              AND q.org_statement_id IS NOT NULL
        JOIN   grac_practice.organization_framework_statements ofs
               ON ofs.org_statement_id = q.org_statement_id
              AND ofs.organization_id  = @organization_id
              AND ofs.status = N'Active'
        JOIN   grac_new.framework_statement fs
               ON fs.framework_statement_id = ofs.framework_statement_id
              AND fs.status = N'Active'
        LEFT JOIN grac_new.source_structure_node n
               ON n.structure_node_id = fs.structure_node_id
              AND n.status = N'Active'
        LEFT JOIN grac_new.release r  ON r.release_id  = ofs.release_id
        LEFT JOIN grac_new.artifact a ON a.artifact_id = r.artifact_id
        WHERE  p.practice_id = @practice_id
          AND  p.organization_id = @organization_id
          AND  p.status = N'Active'
    )
    SELECT TOP (1)
           PracticeId, PracticeCode, PracticeName, OrganizationControlId,
           ControlCode, ControlName, StructureNodeId, NodeTitle,
           StructureName, ReleaseId, FrameworkName
    FROM   (SELECT * FROM old_path UNION ALL SELECT * FROM new_path) x
    ORDER BY SourcePrecedence, StructureNodeId, OrganizationControlId;
END
GO

-- =====================================================================
-- Verification
-- =====================================================================
SELECT '351-a sp_practice_picker_structures reads the new path' AS Check_,
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_practice_picker_structures'))
                 LIKE '%organization_framework_statements%'
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '351-b sp_practice_picker_controls reads the new path',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_practice_picker_controls'))
                 LIKE '%organization_framework_statements%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '351-c sp_practice_picker_controls still reads the OLD path (349)',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_practice_picker_controls'))
                 LIKE '%q.organization_control_id = oc.organization_control_id%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '351-d sp_practice_picker_practices branches on a negative id',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_practice_picker_practices'))
                 LIKE '%IF @organization_control_id < 0%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '351-e sp_practice_picker_practices still supports risk-scope params (312)',
       CASE WHEN EXISTS (SELECT 1 FROM sys.parameters
                          WHERE object_id = OBJECT_ID('grac_practice.sp_practice_picker_practices')
                            AND name = '@risk_register_id')
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '351-f sp_practice_picker_resolve reads the new path',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_practice_picker_resolve'))
                 LIKE '%organization_framework_statements%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '351-g all four procedures still read-only',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_practice_picker_structures')) NOT LIKE '%INSERT INTO grac_practice%'
            AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_practice_picker_controls'))    NOT LIKE '%INSERT INTO grac_practice%'
            AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_practice_picker_practices'))   NOT LIKE '%INSERT INTO grac_practice%'
            AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_practice_picker_resolve'))     NOT LIKE '%INSERT INTO grac_practice%'
            THEN 'PASS' ELSE 'FAIL' END;

-- Section 3: for the organization used in the ISO 27001/UAT diagnostics,
-- does it actually have any new-model adoption yet? If this comes back
-- zero, the picker fix is correct but this SPECIFIC organization will
-- still show an empty tree for ISO 27001 until someone marks statements
-- applicable / creates practices for it in Governance -- that is
-- expected, not a sign this migration did not work. Swap in the real
-- organization_id if it differs from the one earlier diagnostics used.
PRINT '';
PRINT '--- New-model adoption check (adjust @OrganizationId if needed) ---';
DECLARE @OrganizationId BIGINT = (SELECT TOP 1 organization_id FROM grac_practice.organization WHERE organization_name LIKE N'%YogLoans%');
SELECT @OrganizationId AS OrganizationId,
       (SELECT COUNT(*) FROM grac_practice.organization_framework_statements WHERE organization_id = @OrganizationId AND status = N'Active') AS ActiveOrgFrameworkStatements,
       (SELECT COUNT(*) FROM grac_practice.organization_requirement WHERE organization_id = @OrganizationId AND org_statement_id IS NOT NULL AND status = N'Active') AS ActiveOrgRequirementsViaStatement;

PRINT '';
PRINT '351 complete. The Practice Picker now shows Statement/Requirement';
PRINT 'items alongside Control items wherever a release has them. A';
PRINT 'release that still uses real Controls (PCI-DSS) is unaffected --';
PRINT 'both procedures UNION the two paths rather than replacing one with';
PRINT 'the other.';
PRINT '';
PRINT 'No code rebuild is required -- this is a SQL-only change. The API';
PRINT 'and Web tiers call these procedures by name and pass the same';
PRINT 'parameters as before; only the rows the database returns change.';
GO

SET NOEXEC OFF;
GO
