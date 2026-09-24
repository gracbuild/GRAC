-- =====================================================================
-- 282 Practice Picker -- cascading lookup procedures
--
-- WHY
--   Practice selection is used on many forms and today every one of them
--   loads the whole practice list. On a large organisation that is a big
--   payload for a control the user touches once. These five procedures
--   back a reusable cascading picker so each level fetches only the rows
--   under the parent the user just chose.
--
-- THE HIERARCHY -- EVERY EDGE IS REAL, NOTHING IS DERIVED
--     Framework          grac_practice.repository_subscription
--                        (+ grac_new.release / artifact / authority for names)
--        | release_id
--     Source Structure   grac_new.source_structure_node
--        | grac_new.source_control_map (structure_node_id -> control_id)
--     Control            grac_practice.organization_control
--                        (repository_control_id = control_id)
--        | grac_practice.organization_control_requirement   (migration 057)
--     Practice           grac_practice.organization_requirement
--                        -> grac_practice.practice          (practice_id)
--
--   source_control_map is the edge that makes this a literal parent-child
--   walk rather than an inferred one; it is the same join
--   006_sync_organization_controls_from_subscriptions.sql uses to create
--   the organization_control rows in the first place. All five columns it
--   needs are on the 005 preflight contract list, so this does not widen
--   the cross-database surface the product already depends on.
--
-- WHAT THE PICKER RETURNS
--   practice_id from grac_practice.practice -- NOT
--   organization_requirement_id. That is what the existing consumers
--   expect (the Risk Centre posts { practiceId } to
--   /register/{riskId}/practices), so the picker is a drop-in.
--
-- READ-ONLY
--   Every procedure here is a SELECT. No table is created or altered and
--   no row is written, so there is nothing to roll back beyond dropping
--   the procedures.
--
-- Re-runnable: yes (CREATE OR ALTER).
-- Rollback: database/282_practice_picker_procs_rollback.sql
-- DEPENDS ON: 001 (subscription / control / requirement / practice),
--             057 (organization_control_requirement),
--             grac_new: release, artifact, authority,
--                       source_structure_node, source_control_map, control.
-- ASCII-only on purpose (sqlcmd codepage safety).
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

DECLARE @prereqs_ok BIT = 1;

IF OBJECT_ID('grac_practice.organization_control_requirement','U') IS NULL
BEGIN PRINT 'ABORT (282): organization_control_requirement missing. Run 057 first.'; SET @prereqs_ok = 0; END

IF OBJECT_ID('grac_new.source_structure_node','U') IS NULL
   OR OBJECT_ID('grac_new.source_control_map','U') IS NULL
BEGIN PRINT 'ABORT (282): grac_new source tables missing. Run the ControlManagement repository scripts first.'; SET @prereqs_ok = 0; END

IF @prereqs_ok = 0
BEGIN
    RAISERROR('282_practice_picker_procs: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- LEVEL 1 -- Frameworks the organisation is actually subscribed to.
--   Collapses multiple subscriptions against one release to the earliest
--   one, the same way the Repository Subscriptions summary does, so the
--   picker cannot show the same framework twice.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_practice_picker_frameworks
    @organization_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL
        THROW 57001, 'sp_practice_picker_frameworks: organization_id is required.', 1;

    ;WITH subscribed AS (
        SELECT s.release_id,
               COALESCE(s.artifact_id, r.artifact_id) AS artifact_id,
               MIN(s.subscription_id) AS subscription_id
        FROM   grac_practice.repository_subscription s
        JOIN   grac_new.release r ON r.release_id = s.release_id
        WHERE  s.organization_id = @organization_id
          AND  s.status = N'Active'
          AND  ISNULL(s.subscription_status, N'Active') = N'Active'
          AND  s.release_id IS NOT NULL
        GROUP BY s.release_id, COALESCE(s.artifact_id, r.artifact_id)
    )
    SELECT sub.subscription_id                                   AS SubscriptionId,
           sub.release_id                                        AS ReleaseId,
           sub.artifact_id                                       AS ArtifactId,
           auth.authority_name                                   AS AuthorityName,
           a.artifact_name                                       AS ArtifactName,
           r.version_no                                          AS ReleaseVersion,
           COALESCE(a.artifact_code + N' ' + r.version_no,
                    a.artifact_name + N' ' + r.version_no,
                    r.version_no)                                AS FrameworkName
    FROM   subscribed sub
    JOIN   grac_new.release r     ON r.release_id  = sub.release_id
    LEFT JOIN grac_new.artifact a ON a.artifact_id = sub.artifact_id
    LEFT JOIN grac_new.authority auth ON auth.authority_id = a.authority_id

    UNION ALL

    -- Organization-defined practices.
    --   ORG-PRACTICES is the container pm_manage_practice_repository
    --   creates for manually added practices. It has no release and no
    --   structure node BY DESIGN, so a Framework -> Structure -> Control
    --   walk can never reach it and every manual practice would be
    --   invisible in this picker.
    --   Sentinel release id -1 gives those practices a first level to
    --   hang off; sp_practice_picker_structures and _controls recognise
    --   it. -1 cannot collide with a real release_id (IDENTITY, > 0).
    SELECT CAST(-1 AS BIGINT) AS SubscriptionId,
           CAST(-1 AS BIGINT) AS ReleaseId,
           CAST(NULL AS BIGINT) AS ArtifactId,
           CAST(NULL AS NVARCHAR(200)) AS AuthorityName,
           N'Organization Defined' AS ArtifactName,
           CAST(NULL AS NVARCHAR(100)) AS ReleaseVersion,
           N'Organization Defined Practices' AS FrameworkName
    WHERE EXISTS (
        SELECT 1
        FROM   grac_practice.organization_control oc
        JOIN   grac_practice.organization_control_requirement ocr
               ON ocr.organization_control_id = oc.organization_control_id
              AND ocr.status = N'Active'
        WHERE  oc.organization_id = @organization_id
          AND  oc.control_code = N'ORG-PRACTICES'
          AND  oc.origin_type  = N'Organization'
          AND  oc.status = N'Active');
END
GO

-- =====================================================================
-- LEVEL 2 -- Source structures within one framework release.
--   Only nodes that actually lead to a control the organisation holds
--   are returned: an empty branch in the picker is a dead end the user
--   would have to back out of.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_practice_picker_structures
    @organization_id BIGINT,
    @release_id      BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL OR @release_id IS NULL
        THROW 57002, 'sp_practice_picker_structures: organization_id and release_id are required.', 1;

    -- Sentinel release: one synthetic node standing for the whole
    -- organization-defined container.
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

    SELECT n.structure_node_id                       AS StructureNodeId,
           n.parent_node_id                          AS ParentNodeId,
           n.node_level                              AS NodeLevel,
           n.node_reference                          AS NodeReference,
           n.node_title                              AS NodeTitle,
           COALESCE(NULLIF(n.node_reference, N'') + N' - ', N'')
               + n.node_title                        AS StructureName,
           COUNT(DISTINCT oc.organization_control_id) AS ControlCount
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
    GROUP BY n.structure_node_id, n.parent_node_id, n.node_level,
             n.node_reference, n.node_title, n.display_order
    ORDER BY n.display_order, n.node_reference, n.node_title;
END
GO

-- =====================================================================
-- LEVEL 3 -- Controls under one source structure node.
--   PracticeCount lets the UI grey out a control that would open an
--   empty practice list, rather than making the user discover it.
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

    IF @structure_node_id = -1
    BEGIN
        SELECT oc.organization_control_id  AS OrganizationControlId,
               oc.control_code             AS ControlCode,
               oc.control_name             AS ControlName,
               oc.applicability_status     AS ApplicabilityStatus,
               COUNT(DISTINCT p.practice_id) AS PracticeCount
        FROM   grac_practice.organization_control oc
        LEFT JOIN grac_practice.organization_control_requirement ocr
               ON ocr.organization_control_id = oc.organization_control_id
              AND ocr.status = N'Active'
        LEFT JOIN grac_practice.organization_requirement q
               ON q.organization_requirement_id = ocr.organization_requirement_id
              AND q.status = N'Active'
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
    LEFT JOIN grac_practice.organization_control_requirement ocr
           ON ocr.organization_control_id = oc.organization_control_id
          AND ocr.status = N'Active'
    LEFT JOIN grac_practice.organization_requirement q
           ON q.organization_requirement_id = ocr.organization_requirement_id
          AND q.status = N'Active'
    LEFT JOIN grac_practice.practice p
           ON p.organization_requirement_id = q.organization_requirement_id
          AND p.organization_id = @organization_id
          AND p.status = N'Active'
    WHERE  scm.structure_node_id = @structure_node_id
      AND  scm.status = N'Active'
    GROUP BY oc.organization_control_id, oc.control_code,
             oc.control_name, oc.applicability_status
    ORDER BY oc.control_code, oc.control_name;
END
GO

-- =====================================================================
-- LEVEL 4 -- Practices under one control.
--
--   @exclude_practice_ids is a CSV of practice_id the caller already
--   holds, so a form can hide what it has mapped without the picker
--   knowing anything about that form. Empty / NULL excludes nothing.
--   STRING_SPLIT is used rather than a table-valued parameter to keep
--   the ADO.NET call shape identical to every other proc in this
--   codebase (scalar parameters only).
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_practice_picker_practices
    @organization_id        BIGINT,
    @organization_control_id BIGINT,
    @search                 NVARCHAR(200) = NULL,
    @exclude_practice_ids   NVARCHAR(MAX) = NULL
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

    SELECT p.practice_id                        AS PracticeId,
           p.practice_code                      AS PracticeCode,
           p.practice_name                      AS PracticeName,
           p.applicability_status               AS ApplicabilityStatus,
           q.organization_requirement_id        AS OrganizationRequirementId,
           oc.organization_control_id           AS OrganizationControlId,
           oc.control_code                      AS ControlCode
    FROM   grac_practice.organization_control_requirement ocr
    JOIN   grac_practice.organization_control oc
           ON oc.organization_control_id = ocr.organization_control_id
          AND oc.organization_id = @organization_id
          AND oc.status = N'Active'
    JOIN   grac_practice.organization_requirement q
           ON q.organization_requirement_id = ocr.organization_requirement_id
          AND q.status = N'Active'
    JOIN   grac_practice.practice p
           ON p.organization_requirement_id = q.organization_requirement_id
          AND p.organization_id = @organization_id
          AND p.status = N'Active'
    WHERE  ocr.organization_control_id = @organization_control_id
      AND  ocr.status = N'Active'
      AND  NOT EXISTS (SELECT 1 FROM @excluded x WHERE x.practice_id = p.practice_id)
      AND  (@search IS NULL OR LEN(LTRIM(RTRIM(@search))) = 0
            OR p.practice_name LIKE N'%' + @search + N'%'
            OR p.practice_code LIKE N'%' + @search + N'%')
    ORDER BY p.practice_code, p.practice_name;
END
GO

-- =====================================================================
-- EDIT MODE -- resolve a practice back up to its full hierarchy.
--   A form opened on an existing record knows only the practice_id. The
--   picker needs Framework / Structure / Control to show the path the
--   user originally chose.
--
--   A practice can hang off more than one control, and a control can
--   appear under more than one structure node -- that is real in the
--   data, not a modelling error. TOP 1 with a stable ORDER BY returns
--   ONE defensible path (lowest structure node, then lowest control)
--   rather than an arbitrary row, and the picker stays editable if the
--   user wants a different path.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_practice_picker_resolve
    @organization_id BIGINT,
    @practice_id     BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL OR @practice_id IS NULL
        THROW 57005, 'sp_practice_picker_resolve: organization_id and practice_id are required.', 1;

    SELECT TOP (1)
           p.practice_id                  AS PracticeId,
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
                    r.version_no)         AS FrameworkName
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
    ORDER BY n.structure_node_id, oc.organization_control_id;
END
GO

-- =====================================================================
-- Sanity report
-- =====================================================================
SELECT 'sp_practice_picker_frameworks' AS Proc_,
       CASE WHEN OBJECT_ID('grac_practice.sp_practice_picker_frameworks','P') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL SELECT 'sp_practice_picker_structures',
       CASE WHEN OBJECT_ID('grac_practice.sp_practice_picker_structures','P') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT 'sp_practice_picker_controls',
       CASE WHEN OBJECT_ID('grac_practice.sp_practice_picker_controls','P') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT 'sp_practice_picker_practices',
       CASE WHEN OBJECT_ID('grac_practice.sp_practice_picker_practices','P') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT 'sp_practice_picker_resolve',
       CASE WHEN OBJECT_ID('grac_practice.sp_practice_picker_resolve','P') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END;

PRINT '282 Practice Picker procedures complete.';
PRINT 'Smoke test, substituting a real organization id:';
PRINT '  EXEC grac_practice.sp_practice_picker_frameworks @organization_id = 1;';
PRINT '  EXEC grac_practice.sp_practice_picker_structures @organization_id = 1, @release_id = <from above>;';
PRINT '  EXEC grac_practice.sp_practice_picker_controls   @organization_id = 1, @release_id = <..>, @structure_node_id = <..>;';
PRINT '  EXEC grac_practice.sp_practice_picker_practices  @organization_id = 1, @organization_control_id = <..>;';
GO
SET NOEXEC OFF;
GO
