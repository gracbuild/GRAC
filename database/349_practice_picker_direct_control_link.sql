-- =====================================================================
-- 349 Practice Picker -- recognise the direct control FK too
--
-- THE COMPLAINT
--   Governance's own "Practices" grid, filtered to PCI-DSS 7.2, shows 2
--   real practices (REQ-AC-DORMANT-001, REQ-AC-REVIEW-001). The Risk
--   Centre's "Map a practice" picker, on the SAME framework/structure,
--   shows only 1 control (AC-002) and says "(no practices attached)".
--   Same organisation, same requirement rows, two different answers.
--
-- ROOT CAUSE
--   A requirement points at its control TWO ways:
--     (a) organization_requirement.organization_control_id -- direct FK
--     (b) organization_control_requirement (057)            -- many-to-many
--         link table
--
--   Governance's dbo.pm_get_practice_repository (organization-requirements
--   branch, database/002) already reads BOTH, OR'd together, and even
--   self-heals by setting (a) when a repository requirement is browsed
--   for the first time. The practice picker's own procedures
--   (sp_practice_picker_controls / sp_practice_picker_practices, 282,
--   extended by 312) read ONLY (b). A requirement whose direct FK is set
--   but that never got a 057 row -- exactly what REQ-AC-DORMANT-001 and
--   REQ-AC-REVIEW-001 turned out to be -- is invisible to the picker no
--   matter how correct the data otherwise is.
--
-- THE FIX -- SCOPE, DELIBERATELY NARROW
--   Per the decision to keep the picker's four levels
--   (Framework -> Source Structure -> Control -> Practice) exactly as
--   they are, this migration changes ONLY how a requirement is matched
--   to a control inside the two procedures below. Both now accept a
--   requirement reachable by EITHER path:
--
--     q.organization_control_id = oc.organization_control_id     -- (a)
--     OR EXISTS (... organization_control_requirement ... )      -- (b)
--
--   which is the exact OR pattern already used, and already commented,
--   in pm_get_practice_repository. Nothing about the picker's shape,
--   its parameters, or what a caller persists changes -- the Control
--   step in the UI still only ever contributes to filtering, never to
--   what gets saved (confirmed by reading risk-centre.js and
--   exception-centre.js: both post only { practiceId }).
--
-- WHAT CHANGES, PROCEDURE BY PROCEDURE
--   sp_practice_picker_controls (LEVEL 3, from 282)
--     PracticeCount, in BOTH the ORG-PRACTICES sentinel branch and the
--     normal structure-node branch, now counts practices reachable by
--     either path, so a control the picker used to grey out as
--     "(no practices attached)" shows its real count.
--
--   sp_practice_picker_practices (LEVEL 4, current body from 312)
--     Rebuilt on top of 312's full definition -- @risk_register_id,
--     @include_already_mapped, AlreadyMappedToRisk, MapSourceCode,
--     @exclude_practice_ids, @search all preserved byte-for-byte in
--     behaviour. Only the FROM/JOIN that resolves "which requirements
--     belong to this control" changed: it is now driven from
--     organization_control directly (filtered to
--     @organization_control_id) with the OR'd requirement join above,
--     instead of being driven exclusively from the 057 link table.
--
-- WHY THIS IS SAFE
--   Both procedures are pure SELECTs -- nothing is written, nothing is
--   migrated, no existing row changes. A control/practice pair that was
--   already visible via the 057 link table is still matched (the EXISTS
--   branch is untouched); the only thing that changes is that a pair
--   reachable solely via the direct FK becomes visible too. Checked
--   database/328_custom_exception_multi_practice.sql -- it references
--   these procedures only in a comment, it does not redefine either.
--
-- VERIFY AGAINST THE REPORTED CASE
--   EXEC grac_practice.sp_practice_picker_practices
--       @organization_id = <the organisation from the screenshots>,
--       @organization_control_id = <AC-002's organization_control_id>;
--   -- now returns REQ-AC-DORMANT-001 and REQ-AC-REVIEW-001 alongside
--   -- whatever the 057 link table already provided.
--
-- Re-runnable: yes (CREATE OR ALTER).
-- Rollback:   database/349_practice_picker_direct_control_link_rollback.sql
-- DEPENDS ON: 282 (sp_practice_picker_controls / _practices),
--             312 (sp_practice_picker_practices' risk-scope parameters).
-- ASCII-only on purpose (sqlcmd codepage safety).
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

DECLARE @prereqs_ok BIT = 1;

IF OBJECT_ID('grac_practice.sp_practice_picker_controls','P') IS NULL
   OR OBJECT_ID('grac_practice.sp_practice_picker_practices','P') IS NULL
BEGIN
    PRINT 'ABORT (349): sp_practice_picker_controls / _practices missing. Run 282 (and 312) first.';
    SET @prereqs_ok = 0;
END

IF COL_LENGTH('grac_practice.organization_requirement','organization_control_id') IS NULL
BEGIN
    PRINT 'ABORT (349): organization_requirement.organization_control_id missing.';
    SET @prereqs_ok = 0;
END

IF @prereqs_ok = 0
BEGIN
    RAISERROR('349_practice_picker_direct_control_link: prerequisites missing -- see the PRINT messages above. Nothing was changed.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- LEVEL 3 -- Controls under one source structure node.
--   Unchanged signature and shape; PracticeCount now agrees with what
--   LEVEL 4 will actually return, because both read the same two paths.
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
        -- Requirement reachable by EITHER path: the direct FK on
        -- organization_requirement, or the 057 many-to-many link table.
        -- Same OR pattern pm_get_practice_repository already uses.
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
    -- Requirement reachable by EITHER path: the direct FK on
    -- organization_requirement, or the 057 many-to-many link table.
    -- Same OR pattern pm_get_practice_repository already uses, so this
    -- count agrees with what Governance's own grid shows for the same
    -- requirement.
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
    ORDER BY oc.control_code, oc.control_name;
END
GO

-- =====================================================================
-- LEVEL 4 -- Practices under one control.
--   Full body carried forward from 312 (risk-scope parameters, output
--   columns, exclusion and search filters all unchanged). Only the
--   FROM/JOIN that resolves "does this requirement belong to this
--   control" changed, to the same OR'd two-path match as LEVEL 3 above.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_practice_picker_practices
    @organization_id         BIGINT,
    @organization_control_id BIGINT,
    @search                  NVARCHAR(200) = NULL,
    @exclude_practice_ids    NVARCHAR(MAX) = NULL,
    -- From 312. The risk whose scope decides what is already taken.
    -- NULL = no risk in play; nothing is excluded on that basis.
    @risk_register_id        BIGINT        = NULL,
    -- From 312. 0 (default) drops practices this risk already has.
    -- 1 returns them with AlreadyMappedToRisk = 1 instead.
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

    SELECT p.practice_id                        AS PracticeId,
           p.practice_code                      AS PracticeCode,
           p.practice_name                      AS PracticeName,
           p.applicability_status               AS ApplicabilityStatus,
           q.organization_requirement_id        AS OrganizationRequirementId,
           oc.organization_control_id           AS OrganizationControlId,
           oc.control_code                      AS ControlCode,
           -- ORGANISATION **AND** RISK, from 312. Unchanged.
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
    -- Requirement reachable by EITHER path: the direct FK on
    -- organization_requirement, or the 057 many-to-many link table.
    -- Same OR pattern pm_get_practice_repository already uses -- this is
    -- the change that resolves the AC-002/7.2 case: REQ-AC-DORMANT-001
    -- and REQ-AC-REVIEW-001 have their direct FK set but no 057 row.
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
      -- The risk-scoped exclusion, from 312. Unchanged.
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
-- Verification
-- =====================================================================
SELECT '349-a sp_practice_picker_controls reads the direct FK' AS Check_,
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_practice_picker_controls'))
                 LIKE '%q.organization_control_id = oc.organization_control_id%'
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '349-b sp_practice_picker_practices reads the direct FK',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_practice_picker_practices'))
                 LIKE '%q.organization_control_id = oc.organization_control_id%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '349-c sp_practice_picker_practices still checks the 057 link table too',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_practice_picker_practices'))
                 LIKE '%organization_control_requirement%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '349-d 312s @risk_register_id preserved',
       CASE WHEN EXISTS (SELECT 1 FROM sys.parameters
                          WHERE object_id = OBJECT_ID('grac_practice.sp_practice_picker_practices')
                            AND name = '@risk_register_id')
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '349-e 312s @include_already_mapped preserved',
       CASE WHEN EXISTS (SELECT 1 FROM sys.parameters
                          WHERE object_id = OBJECT_ID('grac_practice.sp_practice_picker_practices')
                            AND name = '@include_already_mapped')
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '349-f AlreadyMappedToRisk / MapSourceCode preserved',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_practice_picker_practices'))
                 LIKE '%AS AlreadyMappedToRisk%'
            AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_practice_picker_practices'))
                 LIKE '%MapSourceCode%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '349-g @exclude_practice_ids / @search preserved',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_practice_picker_practices'))
                 LIKE '%FROM @excluded x WHERE x.practice_id = p.practice_id%'
            AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_practice_picker_practices'))
                 LIKE '%p.practice_name LIKE%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '349-h both procedures still read-only',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_practice_picker_controls'))  NOT LIKE '%INSERT INTO grac_practice%'
            AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_practice_picker_controls'))   NOT LIKE '%UPDATE grac_practice%'
            AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_practice_picker_practices'))  NOT LIKE '%INSERT INTO grac_practice%'
            AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_practice_picker_practices'))  NOT LIKE '%UPDATE grac_practice%'
            THEN 'PASS' ELSE 'FAIL' END;

PRINT '';
PRINT '349 complete. sp_practice_picker_controls / _practices now recognise a';
PRINT 'requirement''s direct organization_control_id FK as well as the 057';
PRINT 'organization_control_requirement link table -- matching what';
PRINT 'pm_get_practice_repository (Governance) already does.';
PRINT '';
PRINT 'Smoke test against the reported case:';
PRINT '  EXEC grac_practice.sp_practice_picker_practices';
PRINT '      @organization_id = <organisation from the screenshots>,';
PRINT '      @organization_control_id = <AC-002''s organization_control_id>;';
PRINT '  -- should now list REQ-AC-DORMANT-001 and REQ-AC-REVIEW-001.';
PRINT '';
PRINT 'No code rebuild is required -- this is a SQL-only change. The API';
PRINT 'and Web tiers call these procedures by name and pass the same';
PRINT 'parameters as before; only the rows the database returns change.';
GO

SET NOEXEC OFF;
GO
