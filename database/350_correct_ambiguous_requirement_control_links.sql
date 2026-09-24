-- =====================================================================
-- 350 Correct requirement->control links left ambiguous by an
--     unweighted MIN() tie-break
--
-- THE FINDING (from a live diagnostic on YogLoans / PCI-DSS 4.0)
--   REQ-AC-REVIEW-001 ("Periodic User Access Review") has its direct FK
--   (organization_requirement.organization_control_id) pointing at
--   AC-001 ("User Access Provisioning"). That is wrong:
--     * grac_new.control_requirement_map -- the repository's own
--       requirement -> control catalog -- lists BOTH AC-001 and AC-002
--       ("User Access Review") as valid controls for this requirement's
--       repository_requirement_id. That is a genuinely ambiguous catalog
--       fact, not a data-entry choice.
--     * grac_new.source_control_map -- the repository's structure ->
--       control catalog -- links this requirement's own structure node
--       (7.2, "Access Control Systems", reached through
--       org_statement_id -> organization_framework_statements ->
--       framework_statement.structure_node_id) to AC-002 only. AC-001 is
--       linked to two OTHER nodes (1.2 "Access and Identity Governance"
--       and one unnamed), never to 7.2.
--     * The name itself agrees: "Periodic User Access Review" plainly
--       belongs under "User Access Review" (AC-002), not
--       "User Access Provisioning" (AC-001).
--
--   Three independent signals point at AC-002; the live data has
--   AC-001. That happened because whatever process set the direct FK
--   (283's backfill for a NULL row, or the original seed/import for a
--   row that was never NULL) broke the repository catalog's tie with
--   MIN(organization_control_id) -- 283's own documented rule -- which
--   picks whichever control happens to have the smaller internal id,
--   not the one consistent with where the requirement actually sits in
--   the framework's structure. AC-001 (id 52) sorts before AC-002 (id
--   53) here purely by insertion order.
--
--   This is exactly the class of row 283's own report flags under
--   "NOTE: rows below matched more than one control" -- 283 chooses to
--   proceed with MIN() there rather than block, and never revisits a
--   row once organization_control_id is non-NULL. Nothing before this
--   migration re-examines an ambiguous pick using the structure-node
--   evidence 283 itself gathers as route 2.
--
-- THE FIX
--   For every ACTIVE organization_requirement whose repository catalog
--   mapping (route 1, control_requirement_map) is ambiguous (2 or more
--   candidate controls), intersect those candidates with the control(s)
--   the requirement's OWN structure node names (route 2,
--   source_control_map through its statement). When that intersection
--   is exactly one control, that is the correct one:
--     * if the current organization_control_id already agrees, nothing
--       changes (reported as AlreadyCorrect, for visibility only);
--     * if it disagrees or is NULL, it is corrected;
--     * if the intersection is empty or still has more than one
--       control, NOTHING is changed -- it is reported as StillAmbiguous
--       for a human to resolve, exactly as 283 surfaces what it cannot
--       safely decide.
--   Requirements where route 1 gave zero or exactly one candidate are
--   OUT OF SCOPE here -- those are not the MIN()-tie-break problem this
--   migration exists to correct, and 283 already owns the "NULL and
--   unambiguous" case.
--
-- SAFE, REVERSIBLE, AUDITED
--   Dry run by default (@DryRun = 1): classifies every row, writes
--   nothing. Every row this migration WOULD change (or leaves as still
--   ambiguous) is printed, so the decision is reviewed before it is
--   applied -- never assumed.
--
--   When applied, the PRIOR organization_control_id (including NULL) is
--   written to a small audit table,
--   grac_practice.requirement_control_correction_log, before the
--   correction, so the rollback restores the exact previous value
--   rather than guessing NULL is safe (it would not be, for a row that
--   already had a value before this migration touched it).
--
--   The 057 mapping table (organization_control_requirement) is kept in
--   step: any Active row for the OLD (wrong) control is deactivated,
--   and a row for the NEW (correct) control is inserted or reactivated
--   -- mirroring 283's own habit of writing the direct FK and the 057
--   link together, and 349's OR-both-paths read means either artifact
--   alone would already be enough for the picker to find the practice.
--
-- Re-runnable: yes. A second run finds nothing left to correct.
-- Rollback: database/350_correct_ambiguous_requirement_control_links_rollback.sql
-- DEPENDS ON: 001 (organization_requirement / organization_control_requirement),
--             057 (organization_control_requirement),
--             grac_new: control_requirement_map, framework_statement,
--                       source_control_map (all guarded by OBJECT_ID,
--                       same caveat 283 documents -- not on the 005
--                       preflight contract).
-- ASCII-only on purpose (sqlcmd codepage safety).
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET NOEXEC OFF;
GO

-- ---------------------------------------------------------------------
-- Prerequisites
--   (The @DryRun / @OrganizationId switches live in the batch below,
--   right where they are actually used -- a local variable does not
--   survive a GO, so declaring them up here would silently leave the
--   real switch, further down, unedited by anyone who only changes
--   this copy.)
-- ---------------------------------------------------------------------
IF OBJECT_ID('grac_practice.organization_requirement','U') IS NULL
   OR OBJECT_ID('grac_practice.organization_control','U') IS NULL
BEGIN
    PRINT 'ABORT (350): core tables missing. Run 001 first.';
    RAISERROR('350_correct_ambiguous_requirement_control_links: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END

DECLARE @has_crm BIT = CASE WHEN OBJECT_ID('grac_new.control_requirement_map','U') IS NOT NULL THEN 1 ELSE 0 END;
DECLARE @has_fs  BIT = CASE WHEN OBJECT_ID('grac_new.framework_statement','U')     IS NOT NULL
                             AND OBJECT_ID('grac_new.source_control_map','U')      IS NOT NULL
                             AND OBJECT_ID('grac_practice.organization_framework_statements','U') IS NOT NULL
                            THEN 1 ELSE 0 END;

IF @has_crm = 0 OR @has_fs = 0
BEGIN
    PRINT 'ABORT (350): needs BOTH route 1 (control_requirement_map) and route 2';
    PRINT '             (framework_statement / source_control_map) catalogs to';
    PRINT '             disambiguate safely -- without both this migration cannot';
    PRINT '             tell a genuine correction from a guess, so it does nothing.';
    PRINT '   route 1 available = ' + CAST(@has_crm AS NVARCHAR(1));
    PRINT '   route 2 available = ' + CAST(@has_fs  AS NVARCHAR(1));
    RAISERROR('350_correct_ambiguous_requirement_control_links: repository catalogs unavailable.', 16, 1);
    SET NOEXEC ON;
END
GO

-- ---------------------------------------------------------------------
-- The audit log this migration writes to before ANY UPDATE, so a
-- rollback restores the exact prior value instead of assuming NULL.
-- ---------------------------------------------------------------------
IF OBJECT_ID('grac_practice.requirement_control_correction_log','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.requirement_control_correction_log(
        log_id                       BIGINT IDENTITY(1,1) PRIMARY KEY,
        organization_requirement_id  BIGINT NOT NULL,
        previous_control_id          BIGINT NULL,
        corrected_control_id         BIGINT NOT NULL,
        corrected_by                 NVARCHAR(100) NOT NULL,
        corrected_dt                 DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME()
    );
    PRINT '350: created grac_practice.requirement_control_correction_log.';
END
GO

-- ---------------------------------------------------------------------
-- Switches -- edit these two, then run the whole file.
-- ---------------------------------------------------------------------
DECLARE @DryRun         BIT    = 1;      -- 1 = report only, write nothing
DECLARE @OrganizationId BIGINT = NULL;   -- NULL = all active organizations

-- ---------------------------------------------------------------------
-- Classify every active, repository-linked requirement.
-- ---------------------------------------------------------------------

DECLARE @route1 TABLE(
    organization_requirement_id BIGINT NOT NULL,
    organization_control_id     BIGINT NOT NULL,
    PRIMARY KEY (organization_requirement_id, organization_control_id));

DECLARE @route2 TABLE(
    organization_requirement_id BIGINT NOT NULL,
    organization_control_id     BIGINT NOT NULL,
    structure_node_id           BIGINT NULL,
    structure_reference         NVARCHAR(100) NULL,
    structure_title             NVARCHAR(300) NULL,
    PRIMARY KEY (organization_requirement_id, organization_control_id));

INSERT INTO @route1(organization_requirement_id, organization_control_id)
SELECT DISTINCT r.organization_requirement_id, oc.organization_control_id
FROM   grac_practice.organization_requirement r
JOIN   grac_practice.organization o ON o.organization_id = r.organization_id
JOIN   grac_new.control_requirement_map crm
       ON crm.requirement_id = r.repository_requirement_id AND crm.status = N'Active'
JOIN   grac_practice.organization_control oc
       ON oc.repository_control_id = crm.control_id
      AND oc.organization_id = r.organization_id
      AND oc.status = N'Active'
WHERE  r.status = N'Active' AND o.status = N'Active'
  AND  r.repository_requirement_id IS NOT NULL
  AND (@OrganizationId IS NULL OR r.organization_id = @OrganizationId);

INSERT INTO @route2(organization_requirement_id, organization_control_id, structure_node_id, structure_reference, structure_title)
SELECT DISTINCT r.organization_requirement_id, oc.organization_control_id,
       fs.structure_node_id, n.node_reference, n.node_title
FROM   grac_practice.organization_requirement r
JOIN   grac_practice.organization o ON o.organization_id = r.organization_id
JOIN   grac_practice.organization_framework_statements ofs
       ON ofs.org_statement_id = r.org_statement_id
JOIN   grac_new.framework_statement fs
       ON fs.framework_statement_id = ofs.framework_statement_id
JOIN   grac_new.source_control_map scm
       ON scm.structure_node_id = fs.structure_node_id AND scm.status = N'Active'
JOIN   grac_practice.organization_control oc
       ON oc.repository_control_id = scm.control_id
      AND oc.organization_id = r.organization_id
      AND oc.release_id = ofs.release_id
      AND oc.status = N'Active'
LEFT JOIN grac_new.source_structure_node n
       ON n.structure_node_id = fs.structure_node_id
      AND n.release_id = ofs.release_id
WHERE  r.status = N'Active' AND o.status = N'Active'
  AND  r.org_statement_id IS NOT NULL
  AND (@OrganizationId IS NULL OR r.organization_id = @OrganizationId);

DECLARE @plan TABLE(
    organization_requirement_id BIGINT PRIMARY KEY,
    organization_id             BIGINT,
    requirement_code            NVARCHAR(100),
    requirement_name            NVARCHAR(300),
    current_control_id          BIGINT NULL,
    current_control_code        NVARCHAR(100) NULL,
    route1_candidate_count      INT NOT NULL,
    structure_node_id           BIGINT NULL,
    structure_reference         NVARCHAR(100) NULL,
    structure_title             NVARCHAR(300) NULL,
    route2_candidate_count      INT NOT NULL,
    resolved_control_id         BIGINT NULL,
    resolved_control_code       NVARCHAR(100) NULL,
    action                      NVARCHAR(20) NOT NULL);

;WITH r1 AS (
    SELECT organization_requirement_id, COUNT(*) AS n
    FROM   @route1
    GROUP BY organization_requirement_id
    HAVING COUNT(*) >= 2      -- only rows route 1 itself could not settle
),
resolved AS (
    -- The structure-consistent pick: a control that is BOTH a route 1
    -- candidate AND the (or a) route 2 candidate for this requirement's
    -- own structure node. Only kept when it is the SOLE such control.
    SELECT x.organization_requirement_id,
           MIN(x.organization_control_id) AS resolved_control_id,
           -- DISTINCT on purpose: a requirement's own org_statement_id
           -- resolves to exactly one structure node, so this counts
           -- distinct CONTROLS in the intersection, not incidental
           -- duplicate rows.
           COUNT(DISTINCT x.organization_control_id) AS resolved_count,
           MIN(x.structure_node_id)   AS structure_node_id,
           MIN(x.structure_reference) AS structure_reference,
           MIN(x.structure_title)     AS structure_title
    FROM   (SELECT DISTINCT r2.organization_requirement_id, r2.organization_control_id,
                   r2.structure_node_id, r2.structure_reference, r2.structure_title
            FROM   @route2 r2
            JOIN   @route1 r1x
                   ON r1x.organization_requirement_id = r2.organization_requirement_id
                  AND r1x.organization_control_id     = r2.organization_control_id) x
    GROUP BY x.organization_requirement_id
)
INSERT INTO @plan(organization_requirement_id, organization_id, requirement_code, requirement_name,
                   current_control_id, current_control_code,
                   route1_candidate_count,
                   structure_node_id, structure_reference, structure_title,
                   route2_candidate_count,
                   resolved_control_id, resolved_control_code, action)
SELECT r.organization_requirement_id, r.organization_id, r.requirement_code, r.requirement_name,
       r.organization_control_id, cur.control_code,
       r1.n,
       res.structure_node_id, res.structure_reference, res.structure_title,
       ISNULL(res.resolved_count, 0),
       CASE WHEN res.resolved_count = 1 THEN res.resolved_control_id ELSE NULL END,
       new_oc.control_code,
       CASE
           WHEN res.resolved_count <> 1 THEN N'StillAmbiguous'
           WHEN r.organization_control_id = res.resolved_control_id THEN N'AlreadyCorrect'
           ELSE N'Correct'
       END
FROM   grac_practice.organization_requirement r
JOIN   r1 ON r1.organization_requirement_id = r.organization_requirement_id
LEFT JOIN grac_practice.organization_control cur
       ON cur.organization_control_id = r.organization_control_id
LEFT JOIN resolved res
       ON res.organization_requirement_id = r.organization_requirement_id
LEFT JOIN grac_practice.organization_control new_oc
       ON new_oc.organization_control_id = CASE WHEN res.resolved_count = 1 THEN res.resolved_control_id ELSE NULL END;

-- =====================================================================
-- Report -- always printed, dry run or not.
-- =====================================================================
PRINT '--- 350 PLAN ---';
SELECT action AS Action_, COUNT(*) AS Rows_
FROM   @plan GROUP BY action ORDER BY action;

SELECT organization_requirement_id AS RequirementId,
       organization_id             AS OrganizationId,
       requirement_code            AS Code,
       requirement_name            AS Name,
       current_control_id          AS CurrentControlId,
       current_control_code        AS CurrentControlCode,
       route1_candidate_count      AS RepositoryCandidates,
       structure_reference         AS StructureRef,
       structure_title             AS StructureTitle,
       resolved_control_id         AS ResolvedControlId,
       resolved_control_code       AS ResolvedControlCode,
       action                      AS Action_
FROM   @plan
ORDER BY action, organization_requirement_id;

IF EXISTS (SELECT 1 FROM @plan WHERE action = N'StillAmbiguous')
BEGIN
    PRINT '';
    PRINT 'NOTE: rows above marked StillAmbiguous have 2+ repository candidate';
    PRINT '      controls AND either no route-2 structure evidence or route 2 still';
    PRINT '      leaves more than one candidate. NOTHING was changed for these --';
    PRINT '      they need a human decision, the same way 283 surfaces what it';
    PRINT '      cannot safely resolve.';
END

IF @DryRun = 1
BEGIN
    PRINT '';
    PRINT '350: DRY RUN -- nothing was written. Set @DryRun = 0 to apply.';
END
ELSE
BEGIN
    BEGIN TRAN;

    -- 1. Audit log FIRST, so the previous value is captured before the
    --    UPDATE overwrites it -- including when it was NULL.
    INSERT INTO grac_practice.requirement_control_correction_log
        (organization_requirement_id, previous_control_id, corrected_control_id, corrected_by)
    SELECT organization_requirement_id, current_control_id, resolved_control_id, N'seed-350'
    FROM   @plan
    WHERE  action = N'Correct';

    -- 2. The column itself.
    UPDATE r
    SET    organization_control_id = p.resolved_control_id,
           updated_by = N'seed-350',
           updated_dt = SYSUTCDATETIME()
    FROM   grac_practice.organization_requirement r
    JOIN   @plan p ON p.organization_requirement_id = r.organization_requirement_id
    WHERE  p.action = N'Correct';

    PRINT '350: organization_control_id corrected on = ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + ' row(s)';

    -- 3. Keep 057 in step, same as 283. Deactivate any Active row for
    --    the OLD (wrong) control...
    IF OBJECT_ID('grac_practice.organization_control_requirement','U') IS NOT NULL
    BEGIN
        UPDATE m
        SET    status = N'Inactive',
               updated_by = N'seed-350',
               updated_dt = SYSUTCDATETIME()
        FROM   grac_practice.organization_control_requirement m
        JOIN   @plan p
               ON p.organization_requirement_id = m.organization_requirement_id
              AND p.current_control_id = m.organization_control_id
        WHERE  p.action = N'Correct'
          AND  p.current_control_id IS NOT NULL
          AND  m.status = N'Active';

        PRINT '350: stale 057 mappings deactivated = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));

        -- ...and reactivate or insert a row for the NEW (correct)
        -- control, matching 283's own dedup guard.
        UPDATE m
        SET    status = N'Active',
               updated_by = N'seed-350',
               updated_dt = SYSUTCDATETIME()
        FROM   grac_practice.organization_control_requirement m
        JOIN   @plan p
               ON p.organization_requirement_id = m.organization_requirement_id
              AND p.resolved_control_id = m.organization_control_id
        WHERE  p.action = N'Correct'
          AND  m.status <> N'Active';

        INSERT INTO grac_practice.organization_control_requirement
            (organization_id, organization_control_id, organization_requirement_id, status, entered_by, entered_dt)
        SELECT p.organization_id, p.resolved_control_id, p.organization_requirement_id,
               N'Active', N'seed-350', SYSUTCDATETIME()
        FROM   @plan p
        WHERE  p.action = N'Correct'
          AND  NOT EXISTS (
                   SELECT 1 FROM grac_practice.organization_control_requirement m2
                    WHERE m2.organization_control_id     = p.resolved_control_id
                      AND m2.organization_requirement_id = p.organization_requirement_id);

        PRINT '350: 057 mappings added/reactivated for the corrected control = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
    END

    COMMIT TRAN;

    -- ---- After --------------------------------------------------------
    SELECT 'Rows corrected this run' AS Check_,
           CAST((SELECT COUNT(*) FROM @plan WHERE action = N'Correct') AS NVARCHAR(20)) AS Result
    UNION ALL
    SELECT 'Rows still ambiguous (unchanged)',
           CAST((SELECT COUNT(*) FROM @plan WHERE action = N'StillAmbiguous') AS NVARCHAR(20));

    PRINT '350 correction complete.';
END
GO
SET NOEXEC OFF;
GO
