-- =====================================================================
-- 283 Backfill organization_requirement.organization_control_id
--
-- THE PROBLEM
--   organization_requirement.organization_control_id is written in only
--   two places, both inside dbo.pm_manage_practice_repository under
--   @p_entity_type = 'organization-requirements':
--     * INSERT  -- from $.organizationControlId, else (originType =
--                  'Organization' only) the ORG-PRACTICES container.
--     * UPDATE  -- COALESCE($.organizationControlId, existing).
--   A Repository-origin practice created without an organizationControlId
--   therefore lands with NULL, and NOTHING backfills it afterwards.
--
--   That matters because two things join THROUGH the control:
--     * organization_control_requirement (057) -- whose own backfill is
--       "WHERE r.organization_control_id IS NOT NULL", so a NULL row
--       never gets a mapping;
--     * the cascading Practice Picker (282), which walks
--       Framework -> Structure -> Control -> Practice.
--   A practice with a NULL control is invisible to both.
--
-- WHY 010 IS NOT THE FIX
--   010_sync_organization_requirements_from_applicable_controls.sql is
--   INSERT-only and its guard reads
--       NOT EXISTS (... existing.organization_control_id = c.organization_control_id ...)
--   For an existing row where that column IS NULL the comparison is
--   never true, so NOT EXISTS is satisfied and 010 INSERTS A DUPLICATE
--   practice instead of repairing the original. Do not re-run 010 to fix
--   this.
--
-- ROUTES, IN DESCENDING FIDELITY
--   1. repository_requirement_id -> grac_new.control_requirement_map
--        -> organization_control (repository_control_id).
--      The route the row should have taken; the same join 002 and 010
--      use.
--   2. org_statement_id -> organization_framework_statements
--        -> grac_new.framework_statement.structure_node_id
--        -> grac_new.source_control_map -> organization_control.
--      For statement-origin practices.
--   3. The organisation's ORG-PRACTICES container -- the same catch-all
--      the manual-entry path already uses. Only applied when asked for
--      (@UseOrgPracticesFallback), because it asserts a relationship
--      rather than discovering one.
--
--   Ambiguity is resolved by MIN(organization_control_id), and any row
--   whose route yields more than one candidate control is reported, so a
--   silent arbitrary pick never happens unnoticed.
--
-- DRY RUN BY DEFAULT
--   @DryRun = 1 classifies every NULL row, prints the plan and writes
--   NOTHING. Read the output, confirm the routes are right for your
--   data, then set @DryRun = 0.
--
-- CROSS-DATABASE CAVEAT
--   grac_new.control_requirement_map and grac_new.framework_statement
--   are NOT on the 005 preflight contract, even though 002 / 010 already
--   join to them. Each route is guarded by OBJECT_ID and simply does not
--   run if its table is absent.
--
-- Re-runnable: yes. A second live run finds nothing left to fix.
-- Rollback: database/283_backfill_requirement_control_id_rollback.sql
-- DEPENDS ON: 001, 010, 057.
-- ASCII-only on purpose (sqlcmd codepage safety).
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET NOEXEC OFF;
GO

-- ---------------------------------------------------------------------
-- Switches
-- ---------------------------------------------------------------------
DECLARE @DryRun                  BIT    = 1;      -- 1 = report only, write nothing
DECLARE @OrganizationId          BIGINT = NULL;   -- NULL = all active organizations
DECLARE @UseOrgPracticesFallback BIT    = 0;      -- 1 = route 3 for whatever routes 1/2 miss
-- A practice legitimately satisfying several controls is normal in GRC,
-- and organization_control_requirement (057) is a many-to-many table
-- built for exactly that. organization_control_id can hold only ONE, so
-- it takes the primary (MIN) either way.
--   0 = map ONLY the primary control (conservative, current behaviour)
--   1 = map EVERY candidate control, so the practice is findable under
--       each control it actually satisfies
-- See the note under "MULTI-CONTROL PRACTICES" in the header.
DECLARE @MapAllCandidateControls BIT    = 0;

-- ---------------------------------------------------------------------
-- Prerequisites
-- ---------------------------------------------------------------------
IF OBJECT_ID('grac_practice.organization_requirement','U') IS NULL
   OR OBJECT_ID('grac_practice.organization_control','U') IS NULL
BEGIN
    PRINT 'ABORT (283): core tables missing. Run 001 first.';
    RAISERROR('283_backfill_requirement_control_id: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END

DECLARE @has_crm BIT = CASE WHEN OBJECT_ID('grac_new.control_requirement_map','U') IS NOT NULL THEN 1 ELSE 0 END;
DECLARE @has_fs  BIT = CASE WHEN OBJECT_ID('grac_new.framework_statement','U')     IS NOT NULL
                             AND OBJECT_ID('grac_new.source_control_map','U')      IS NOT NULL
                             AND OBJECT_ID('grac_practice.organization_framework_statements','U') IS NOT NULL
                            THEN 1 ELSE 0 END;

PRINT '283: route 1 (control_requirement_map) available = ' + CAST(@has_crm AS NVARCHAR(1));
PRINT '283: route 2 (statement -> structure node)   available = ' + CAST(@has_fs  AS NVARCHAR(1));

-- ---------------------------------------------------------------------
-- Classify every NULL row.
-- ---------------------------------------------------------------------
DECLARE @plan TABLE(
    organization_requirement_id BIGINT PRIMARY KEY,
    organization_id             BIGINT,
    requirement_code            NVARCHAR(100),
    requirement_name            NVARCHAR(300),
    origin_type                 NVARCHAR(30),
    route                       NVARCHAR(40),
    resolved_control_id         BIGINT NULL,
    candidate_count             INT NOT NULL DEFAULT 0);

-- Every (requirement, control) pair a route found -- not just the
-- primary. Kept so @MapAllCandidateControls can write them all.
DECLARE @candidate TABLE(
    organization_requirement_id BIGINT NOT NULL,
    organization_control_id     BIGINT NOT NULL,
    route                       NVARCHAR(40) NOT NULL,
    PRIMARY KEY (organization_requirement_id, organization_control_id));

INSERT INTO @plan(organization_requirement_id, organization_id, requirement_code, requirement_name, origin_type, route)
SELECT r.organization_requirement_id, r.organization_id, r.requirement_code, r.requirement_name,
       r.origin_type, N'Unresolved'
FROM   grac_practice.organization_requirement r
JOIN   grac_practice.organization o ON o.organization_id = r.organization_id
WHERE  r.organization_control_id IS NULL
  AND  r.status = N'Active'
  AND  o.status = N'Active'
  AND (@OrganizationId IS NULL OR r.organization_id = @OrganizationId);

-- ---- Route 1: repository_requirement_id -> control_requirement_map ---
IF @has_crm = 1
BEGIN
    INSERT INTO @candidate(organization_requirement_id, organization_control_id, route)
    SELECT DISTINCT p.organization_requirement_id, oc.organization_control_id, N'1-RepositoryMap'
    FROM   @plan p
    JOIN   grac_practice.organization_requirement r
           ON r.organization_requirement_id = p.organization_requirement_id
    JOIN   grac_new.control_requirement_map crm
           ON crm.requirement_id = r.repository_requirement_id AND crm.status = N'Active'
    JOIN   grac_practice.organization_control oc
           ON oc.repository_control_id = crm.control_id
          AND oc.organization_id = p.organization_id
          AND oc.status = N'Active'
    WHERE  r.repository_requirement_id IS NOT NULL;

    ;WITH c AS (
        SELECT p.organization_requirement_id,
               MIN(oc.organization_control_id)   AS control_id,
               COUNT(DISTINCT oc.organization_control_id) AS n
        FROM   @plan p
        JOIN   grac_practice.organization_requirement r
               ON r.organization_requirement_id = p.organization_requirement_id
        JOIN   grac_new.control_requirement_map crm
               ON crm.requirement_id = r.repository_requirement_id
              AND crm.status = N'Active'
        JOIN   grac_practice.organization_control oc
               ON oc.repository_control_id = crm.control_id
              AND oc.organization_id = p.organization_id
              AND oc.status = N'Active'
        WHERE  r.repository_requirement_id IS NOT NULL
        GROUP BY p.organization_requirement_id
    )
    UPDATE p
    SET    route = N'1-RepositoryMap',
           resolved_control_id = c.control_id,
           candidate_count = c.n
    FROM   @plan p JOIN c ON c.organization_requirement_id = p.organization_requirement_id;
END

-- ---- Route 2: org_statement_id -> structure node -> control ---------
IF @has_fs = 1
BEGIN
    INSERT INTO @candidate(organization_requirement_id, organization_control_id, route)
    SELECT DISTINCT p.organization_requirement_id, oc.organization_control_id, N'2-StatementNode'
    FROM   @plan p
    JOIN   grac_practice.organization_requirement r
           ON r.organization_requirement_id = p.organization_requirement_id
    JOIN   grac_practice.organization_framework_statements ofs
           ON ofs.org_statement_id = r.org_statement_id
    JOIN   grac_new.framework_statement fs
           ON fs.framework_statement_id = ofs.framework_statement_id
    JOIN   grac_new.source_control_map scm
           ON scm.structure_node_id = fs.structure_node_id AND scm.status = N'Active'
    JOIN   grac_practice.organization_control oc
           ON oc.repository_control_id = scm.control_id
          AND oc.organization_id = p.organization_id
          AND oc.release_id = ofs.release_id
          AND oc.status = N'Active'
    WHERE  p.route = N'Unresolved'
      AND  r.org_statement_id IS NOT NULL
      AND  NOT EXISTS (SELECT 1 FROM @candidate x
                        WHERE x.organization_requirement_id = p.organization_requirement_id
                          AND x.organization_control_id = oc.organization_control_id);

    ;WITH c AS (
        SELECT p.organization_requirement_id,
               MIN(oc.organization_control_id)   AS control_id,
               COUNT(DISTINCT oc.organization_control_id) AS n
        FROM   @plan p
        JOIN   grac_practice.organization_requirement r
               ON r.organization_requirement_id = p.organization_requirement_id
        JOIN   grac_practice.organization_framework_statements ofs
               ON ofs.org_statement_id = r.org_statement_id
        JOIN   grac_new.framework_statement fs
               ON fs.framework_statement_id = ofs.framework_statement_id
        JOIN   grac_new.source_control_map scm
               ON scm.structure_node_id = fs.structure_node_id
              AND scm.status = N'Active'
        JOIN   grac_practice.organization_control oc
               ON oc.repository_control_id = scm.control_id
              AND oc.organization_id = p.organization_id
              AND oc.release_id = ofs.release_id
              AND oc.status = N'Active'
        WHERE  p.route = N'Unresolved'
          AND  r.org_statement_id IS NOT NULL
        GROUP BY p.organization_requirement_id
    )
    UPDATE p
    SET    route = N'2-StatementNode',
           resolved_control_id = c.control_id,
           candidate_count = c.n
    FROM   @plan p JOIN c ON c.organization_requirement_id = p.organization_requirement_id;
END

-- ---- Route 3: ORG-PRACTICES container (opt-in) ----------------------
IF @UseOrgPracticesFallback = 1
BEGIN
    ;WITH c AS (
        SELECT p.organization_requirement_id,
               MIN(oc.organization_control_id) AS control_id
        FROM   @plan p
        JOIN   grac_practice.organization_control oc
               ON oc.organization_id = p.organization_id
              AND oc.control_code = N'ORG-PRACTICES'
              AND oc.origin_type  = N'Organization'
              AND oc.status = N'Active'
        WHERE  p.route = N'Unresolved'
        GROUP BY p.organization_requirement_id
    )
    UPDATE p
    SET    route = N'3-OrgPractices',
           resolved_control_id = c.control_id,
           candidate_count = 1
    FROM   @plan p JOIN c ON c.organization_requirement_id = p.organization_requirement_id;
END

-- =====================================================================
-- Report -- always printed, dry run or not.
-- =====================================================================
PRINT '--- 283 PLAN ---';
SELECT route AS Route, COUNT(*) AS Rows_
FROM   @plan GROUP BY route ORDER BY route;

SELECT organization_requirement_id AS RequirementId,
       organization_id             AS OrganizationId,
       requirement_code            AS Code,
       requirement_name            AS Name,
       origin_type                 AS Origin,
       route                       AS Route,
       resolved_control_id         AS WillSetControlId,
       candidate_count             AS CandidateControls
FROM   @plan
ORDER BY route, organization_requirement_id;

-- A row with more than one candidate control took MIN(); surface it so
-- the choice is reviewed rather than assumed.
IF EXISTS (SELECT 1 FROM @plan WHERE candidate_count > 1)
BEGIN
    PRINT 'NOTE: rows below matched more than one control. MIN(organization_control_id) was used.';
    SELECT p.organization_requirement_id AS RequirementId, p.requirement_code AS Code,
           p.route AS Route, p.candidate_count AS CandidateControls,
           p.resolved_control_id AS PrimaryChosen,
           c.organization_control_id AS CandidateControlId,
           oc.control_code AS CandidateControlCode,
           oc.control_name AS CandidateControlName,
           CASE WHEN c.organization_control_id = p.resolved_control_id
                THEN 'PRIMARY' ELSE 'extra' END AS Role_
    FROM   @plan p
    JOIN   @candidate c ON c.organization_requirement_id = p.organization_requirement_id
    JOIN   grac_practice.organization_control oc ON oc.organization_control_id = c.organization_control_id
    WHERE  p.candidate_count > 1
    ORDER BY p.organization_requirement_id, c.organization_control_id;

    IF @MapAllCandidateControls = 1
        PRINT 'PLAN: @MapAllCandidateControls = 1 -- a mapping row will be written for EVERY candidate above.';
    ELSE
        PRINT 'PLAN: @MapAllCandidateControls = 0 -- only the PRIMARY control will be mapped.';
END

IF EXISTS (SELECT 1 FROM @plan WHERE route = N'Unresolved')
    PRINT 'NOTE: unresolved rows stay NULL. Set @UseOrgPracticesFallback = 1 to place them in ORG-PRACTICES.';

IF @DryRun = 1
BEGIN
    PRINT '';
    PRINT '283: DRY RUN -- nothing was written. Set @DryRun = 0 to apply.';
END
ELSE
BEGIN
    BEGIN TRAN;

    -- 1. The column itself.
    UPDATE r
    SET    organization_control_id = p.resolved_control_id,
           updated_by = N'seed-283',
           updated_dt = SYSUTCDATETIME()
    FROM   grac_practice.organization_requirement r
    JOIN   @plan p ON p.organization_requirement_id = r.organization_requirement_id
    WHERE  p.resolved_control_id IS NOT NULL
      AND  r.organization_control_id IS NULL;

    PRINT '283: organization_control_id set on = ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + ' row(s)';

    -- 2. The 057 mapping row, which is what the Practice Picker and the
    --    control-applicability flow actually read. Mirrors 057's own
    --    backfill, including its duplicate guard.
    IF OBJECT_ID('grac_practice.organization_control_requirement','U') IS NOT NULL
    BEGIN
        -- @MapAllCandidateControls = 0 -> the primary control only.
        -- @MapAllCandidateControls = 1 -> every candidate, which is what
        -- the many-to-many table exists for and what makes a practice
        -- findable under each control it genuinely satisfies.
        INSERT INTO grac_practice.organization_control_requirement
            (organization_id, organization_control_id, organization_requirement_id, status, entered_by, entered_dt)
        SELECT r.organization_id, x.organization_control_id, r.organization_requirement_id,
               CASE WHEN r.status = N'Active' THEN N'Active' ELSE N'Inactive' END,
               N'seed-283', SYSUTCDATETIME()
        FROM   grac_practice.organization_requirement r
        JOIN   @plan p ON p.organization_requirement_id = r.organization_requirement_id
        CROSS APPLY (
            SELECT c.organization_control_id
            FROM   @candidate c
            WHERE  c.organization_requirement_id = p.organization_requirement_id
              AND (@MapAllCandidateControls = 1
                   OR c.organization_control_id = p.resolved_control_id)
            UNION
            -- Route 3 writes no candidate rows, so take the resolved id.
            SELECT p.resolved_control_id
            WHERE  p.resolved_control_id IS NOT NULL
              AND  NOT EXISTS (SELECT 1 FROM @candidate c2
                                WHERE c2.organization_requirement_id = p.organization_requirement_id)
        ) AS x
        WHERE  x.organization_control_id IS NOT NULL
          AND  NOT EXISTS (
                   SELECT 1 FROM grac_practice.organization_control_requirement m
                    WHERE m.organization_control_id     = x.organization_control_id
                      AND m.organization_requirement_id = r.organization_requirement_id);

        PRINT '283: control-requirement mappings added = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
    END

    COMMIT TRAN;

    -- ---- After ------------------------------------------------------
    SELECT 'Remaining NULL control ids' AS Check_,
           CAST(COUNT(*) AS NVARCHAR(20)) AS Result
    FROM   grac_practice.organization_requirement r
    JOIN   grac_practice.organization o ON o.organization_id = r.organization_id
    WHERE  r.organization_control_id IS NULL
      AND  r.status = N'Active' AND o.status = N'Active'
      AND (@OrganizationId IS NULL OR r.organization_id = @OrganizationId);

    SELECT 'Practices now reachable through a control' AS Check_,
           CAST(COUNT(DISTINCT p.practice_id) AS NVARCHAR(20)) AS Result
    FROM   grac_practice.organization_control_requirement ocr
    JOIN   grac_practice.organization_requirement q
           ON q.organization_requirement_id = ocr.organization_requirement_id AND q.status = N'Active'
    JOIN   grac_practice.practice p
           ON p.organization_requirement_id = q.organization_requirement_id AND p.status = N'Active'
    WHERE  ocr.status = N'Active'
      AND (@OrganizationId IS NULL OR q.organization_id = @OrganizationId);

    PRINT '283 backfill complete.';
END
GO
SET NOEXEC OFF;
GO
