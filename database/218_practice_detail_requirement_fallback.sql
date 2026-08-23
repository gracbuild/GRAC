-- =====================================================================
-- 218 sp_practice_detail_get -- fall back to organization_requirement
--
-- SYMPTOM
-- -------
-- Organization Practices -> 3-dot menu -> View, on a practice that has
-- not been marked Applicable:
--     "This practice could not be loaded (HTTP 404)."
--
-- CAUSE
-- -----
-- The chain, end to end:
--
--   practice.js allowedAction 'view'
--     -> the Organization Practices grid gets PracticeId from an
--        OUTER APPLY over grac_practice.practice, which yields NULL when
--        no practice row exists, so it navigates with
--        filterType = 'OrganizationRequirement'
--     -> practice-view.cshtml calls
--        /api/practice/workflow/practice-configure/detail?organizationRequirementId=...
--     -> PracticeConfigureService.GetPracticeDetailAsync
--     -> grac_practice.sp_practice_detail_get
--        THROW 52500 'no practice found'
--     -> service catches, returns Success = false
--     -> PracticeConfigureController returns NotFound()  == HTTP 404
--
-- grac_practice.practice rows are created lazily: by a save through the
-- organization-requirements branch of pm_manage_practice_repository
-- (Mark Applicability included), or when an instance is configured. A
-- requirement that arrived through the 010 sync and has never been
-- touched has no practice row at all -- and those untouched rows are
-- exactly the ones still sitting at "Not Updated".
--
-- FIX
-- ---
-- When the requirement resolves to no practice, return the header from
-- grac_practice.organization_requirement instead of throwing. Every
-- field the page renders -- code, name, description, origin, applicability,
-- status -- lives on the requirement too. The two that do not:
--   * PracticeId          -> 0  (there is no practice yet)
--   * PracticeOwner(Id)   -> NULL (owner is a practice column)
--   * ActiveInstanceCount -> 0  (no practice, so no instances)
--
-- PracticeId = 0 rather than NULL on purpose:
-- PracticeConfigureService reads it with Convert.ToInt64, which throws on
-- DBNull. 0 is also what practice-view.cshtml now tests to decide whether
-- to show Configure -- see the Web-side change that ships with this
-- migration.
--
-- The column list, names and types of the fallback SELECT are identical
-- to the practice SELECT below it. The reader binds by name, so the two
-- must not drift.
--
-- NOT DOING: materialising a practice row here. This is a read path; a
-- GET that writes would create practice rows for Not Applicable
-- requirements as a side effect of somebody merely looking at one.
--
-- ASCII-only on purpose (sqlcmd codepage).
-- Idempotent: CREATE OR ALTER only, no data touched.
--
-- DEPENDS ON: 139 (the procedure), 001/002 (organization_requirement).
-- Rollback:   database/218_practice_detail_requirement_fallback_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

DECLARE @prereqs_ok BIT = 1;

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    PRINT 'ABORT (218): schema grac_practice missing.';
    SET @prereqs_ok = 0;
END

IF OBJECT_ID('grac_practice.sp_practice_detail_get','P') IS NULL
BEGIN
    PRINT 'ABORT (218): sp_practice_detail_get missing. Run 139_practice_configure_teams.sql first.';
    SET @prereqs_ok = 0;
END

IF OBJECT_ID('grac_practice.organization_requirement','U') IS NULL
   OR OBJECT_ID('grac_practice.practice','U') IS NULL
BEGIN
    PRINT 'ABORT (218): organization_requirement or practice missing. Run 001/002 first.';
    SET @prereqs_ok = 0;
END

IF @prereqs_ok = 0
BEGIN
    RAISERROR('218_practice_detail_requirement_fallback: prerequisites missing -- see PRINT messages above.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- sp_practice_detail_get -- re-issued from the 139 body with the
-- requirement fallback inserted between the practice resolution and the
-- 52500 throw. Everything else is unchanged; keep the two in step if 139
-- is ever revised.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_practice_detail_get
    @practice_id                BIGINT = NULL,
    @organization_id            BIGINT = NULL,
    @organization_requirement_id BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    -- The caller may know either identifier. The Organization Practices grid
    -- is one row per organization_requirement and does not always carry the
    -- practice id, so accepting the requirement id and resolving from it here
    -- keeps the page working regardless of which column that grid returns.
    -- When a requirement has several practices, the earliest active one is
    -- the practice the grid itself displays.
    IF @practice_id IS NULL AND @organization_requirement_id IS NOT NULL
        SELECT TOP 1 @practice_id = practice_id
        FROM   grac_practice.practice
        WHERE  organization_requirement_id = @organization_requirement_id
          AND (@organization_id IS NULL OR organization_id = @organization_id)
        ORDER  BY CASE WHEN status = N'Active' THEN 0 ELSE 1 END, practice_id;

    -- (218) No practice row yet -- serve the header straight from the
    -- requirement rather than 404-ing the page. See the file header for why
    -- this state is normal rather than a data fault.
    IF @practice_id IS NULL AND @organization_requirement_id IS NOT NULL
    BEGIN
        IF NOT EXISTS (SELECT 1
                       FROM   grac_practice.organization_requirement
                       WHERE  organization_requirement_id = @organization_requirement_id
                         AND (@organization_id IS NULL OR organization_id = @organization_id))
            THROW 52512, 'sp_practice_detail_get: requirement not found for this organization.', 1;

        SELECT
            CAST(0 AS BIGINT)                 AS PracticeId,
            q.organization_id                 AS OrganizationId,
            o.organization_name               AS OrganizationName,
            q.requirement_code                AS PracticeCode,
            q.requirement_name                AS PracticeName,
            q.requirement_statement           AS Description,
            q.origin_type                     AS OriginType,
            CAST(NULL AS NVARCHAR(200))       AS PracticeOwner,
            CAST(NULL AS BIGINT)              AS PracticeOwnerId,
            COALESCE(aps.status_name, q.applicability_status) AS ApplicabilityStatus,
            q.exclusion_justification         AS ExclusionJustification,
            COALESCE(rs.status_name, q.status) AS Status,
            q.organization_requirement_id     AS OrganizationRequirementId,
            q.requirement_code                AS RequirementCode,
            q.requirement_name                AS RequirementName,
            CAST(0 AS INT)                    AS ActiveInstanceCount
        FROM   grac_practice.organization_requirement q
        JOIN   grac_practice.organization o
               ON o.organization_id = q.organization_id
        LEFT   JOIN grac_practice.applicability_status_master aps
               ON aps.applicability_status_id = q.applicability_status_id
        LEFT   JOIN grac_practice.record_status_master rs
               ON rs.record_status_id = q.record_status_id
        WHERE  q.organization_requirement_id = @organization_requirement_id
          AND (@organization_id IS NULL OR q.organization_id = @organization_id);

        RETURN;
    END

    IF @practice_id IS NULL
        THROW 52500, 'sp_practice_detail_get: no practice found. Supply practice_id, or an organization_requirement_id that has a practice.', 1;

    IF NOT EXISTS (SELECT 1 FROM grac_practice.practice
                    WHERE practice_id = @practice_id
                      AND (@organization_id IS NULL OR organization_id = @organization_id))
        THROW 52501, 'sp_practice_detail_get: practice not found for this organization.', 1;

    SELECT
        p.practice_id                    AS PracticeId,
        p.organization_id                AS OrganizationId,
        o.organization_name              AS OrganizationName,
        p.practice_code                  AS PracticeCode,
        p.practice_name                  AS PracticeName,
        p.description                    AS Description,
        p.origin_type                    AS OriginType,
        p.practice_owner                 AS PracticeOwner,
        p.practice_owner_id              AS PracticeOwnerId,
        p.applicability_status           AS ApplicabilityStatus,
        p.exclusion_justification        AS ExclusionJustification,
        p.status                         AS Status,
        p.organization_requirement_id    AS OrganizationRequirementId,
        req.requirement_code             AS RequirementCode,
        req.requirement_name             AS RequirementName,
        (SELECT COUNT(*)
         FROM   grac_practice.practice_instance pi
         WHERE  pi.practice_id = p.practice_id
           AND  pi.status = N'Active')   AS ActiveInstanceCount
    FROM   grac_practice.practice p
    JOIN   grac_practice.organization o
           ON o.organization_id = p.organization_id
    LEFT   JOIN grac_practice.organization_requirement req
           ON req.organization_requirement_id = p.organization_requirement_id
    WHERE  p.practice_id = @practice_id;
END
GO

-- =====================================================================
-- Sanity report
-- =====================================================================
SELECT 'sp_practice_detail_get present' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.sp_practice_detail_get','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;

-- How many requirements were 404-ing before this migration. Non-zero is
-- expected and is the point of the change; it is the row count the View
-- action can now open.
SELECT 'Requirements with no practice row (previously HTTP 404 on View)' AS Check_,
       COUNT(*) AS RequirementCount
FROM   grac_practice.organization_requirement q
WHERE  NOT EXISTS (SELECT 1
                   FROM   grac_practice.practice p
                   WHERE  p.organization_requirement_id = q.organization_requirement_id);

-- Spot-check payload for the first such requirement, so the fallback can be
-- eyeballed without opening the UI.
DECLARE @sample_requirement_id BIGINT = (
    SELECT TOP 1 q.organization_requirement_id
    FROM   grac_practice.organization_requirement q
    WHERE  NOT EXISTS (SELECT 1
                       FROM   grac_practice.practice p
                       WHERE  p.organization_requirement_id = q.organization_requirement_id)
    ORDER  BY q.organization_requirement_id
);

IF @sample_requirement_id IS NOT NULL
BEGIN
    PRINT '218: sample fallback row for organization_requirement_id = '
          + CAST(@sample_requirement_id AS NVARCHAR(20));
    EXEC grac_practice.sp_practice_detail_get
         @practice_id                 = NULL,
         @organization_id             = NULL,
         @organization_requirement_id = @sample_requirement_id;
END
ELSE
    PRINT '218: every requirement already has a practice row -- nothing to sample.';
GO

PRINT '218 sp_practice_detail_get requirement fallback complete.';
GO

SET NOEXEC OFF;
GO
