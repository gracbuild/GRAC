-- =====================================================================
-- 218 sp_practice_detail_get requirement fallback -- ROLLBACK
--
-- Restores grac_practice.sp_practice_detail_get to the exact
-- 139_practice_configure_teams.sql body: no requirement fallback, so a
-- requirement with no grac_practice.practice row throws 52500 again and
-- the View page returns to "This practice could not be loaded (HTTP 404)".
--
-- No data to undo -- 218 only replaced a procedure.
--
-- The Web-side change that shipped with 218 (practice-view.cshtml hiding
-- Configure when PracticeId is 0) is harmless on its own: with this
-- rollback applied the fallback never fires, so PracticeId is always a
-- real practice id and Configure shows exactly as before.
--
-- ASCII-only on purpose (sqlcmd codepage).
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    PRINT 'ABORT (218 rollback): schema grac_practice missing.';
    SET NOEXEC ON;
END
GO

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

SELECT 'sp_practice_detail_get restored to the 139 body' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.sp_practice_detail_get','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;

PRINT '218 sp_practice_detail_get requirement fallback rollback complete.';
GO

SET NOEXEC OFF;
GO
