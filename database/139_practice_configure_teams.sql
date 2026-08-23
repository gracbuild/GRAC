-- =====================================================================
-- 139 Practice Configure -- create one Practice Instance per Team
--
-- WHAT THIS REPLACES
-- ------------------
-- Practice Instances were created one at a time on their own Add form,
-- where the user typed an instance code, an instance name and picked an
-- owner. In practice an instance is always "this practice, carried out by
-- this team", so all three fields were derivable and typing them by hand
-- was both work and a source of inconsistency.
--
-- Configure replaces that: pick the teams, and one instance is created per
-- team with
--     instance_name = <practice name>-<team name>
--     instance_code = PR_001, PR_002, ... (next free number in the org)
--     primary_owner = the team's manager
--
-- and the Team dependency is declared and resolved in the same breath, so
-- the instance lands operationally complete rather than needing a second
-- trip through the Resolve screen.
--
-- ADD-ONLY, DELIBERATELY
-- ----------------------
-- Re-running Configure creates instances only for teams that do not have
-- one yet. Un-ticking a team does NOT retire its instance. By the time a
-- team has an instance it may also have evidence, assurance activities and
-- open tasks hanging off it; losing those to a stray click is far worse
-- than leaving one instance too many on screen. Retiring an instance stays
-- an explicit act on the Practice Instances screen.
--
-- CODE SEQUENCE
-- -------------
-- PR_nnn is allocated per ORGANIZATION, not per practice, because the
-- uniqueness constraint on the table is uq_pm_practice_instance
-- (organization_id, instance_code). A per-practice sequence would collide
-- the moment two practices in one organization both reached PR_001.
--
-- OWNERLESS INSTANCES
-- -------------------
-- If a team has no manager the instance is still created, with no owner,
-- and the result set says so (HasOwner = 0). Such an instance is not yet
-- assurance-eligible -- the eligibility test in pm_get_practice_repository
-- requires primary_owner -- so the caller is expected to surface this
-- rather than swallow it.
--
-- Objects:
--   grac_practice.sp_practice_detail_get
--   grac_practice.sp_practice_team_option_list
--   grac_practice.sp_practice_instance_configure
--
-- Error codes 52500-52512 (52400s belong to 136, 52300s to 133).
-- Depends on 001/002 (practice, practice_instance, dependency tables),
-- 015 (dependency_type_master), 021 (primary_owner_id / department_id).
-- Rollback: 139_practice_configure_teams_rollback.sql.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.practice','U') IS NULL
   OR OBJECT_ID('grac_practice.practice_instance','U') IS NULL
   OR OBJECT_ID('grac_practice.organization_team','U') IS NULL
   OR OBJECT_ID('grac_practice.practice_instance_dependency','U') IS NULL
   OR OBJECT_ID('grac_practice.practice_dependency_resolution','U') IS NULL
   OR OBJECT_ID('grac_practice.dependency_type_master','U') IS NULL
BEGIN
    RAISERROR('139: prerequisites missing. Run 001, 002 and 015 first.', 16, 1);
    SET NOEXEC ON;
END
GO

IF COL_LENGTH('grac_practice.practice_instance','primary_owner_id') IS NULL
   OR COL_LENGTH('grac_practice.practice_instance','department_id') IS NULL
BEGIN
    RAISERROR('139: practice_instance.primary_owner_id / department_id missing. Run 021 first.', 16, 1);
    SET NOEXEC ON;
END
GO

IF NOT EXISTS (SELECT 1 FROM grac_practice.dependency_type_master
                WHERE dependency_type_code = N'TEAM' OR dependency_type_name = N'Team')
BEGIN
    RAISERROR('139: no Team row in dependency_type_master. Run 002 seeds first.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. sp_practice_detail_get
--
--    Header for the full-page Practice view. One row. Deliberately does
--    not join the obligation tables: obligations come from
--    dbo.sp_pm_view_obligations_typed (migration 122), which already
--    accepts @p_practice_id and returns the typed shape the existing
--    View Obligations panel renders.
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
-- 2. sp_practice_team_option_list
--
--    The multi-select feed. One row per active team in the organization,
--    carrying the manager (who becomes the instance owner) and whether
--    this practice already has an instance for that team.
--
--    "Already configured" is read from the resolution table rather than
--    by parsing instance names: names are editable, resolutions are the
--    actual link between an instance and a team.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_practice_team_option_list
    @organization_id BIGINT,
    @practice_id     BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @organization_id IS NULL
        THROW 52502, 'sp_practice_team_option_list: organization_id is required.', 1;

    DECLARE @team_type_id INT = (
        SELECT TOP 1 dependency_type_id
        FROM   grac_practice.dependency_type_master
        WHERE  dependency_type_code = N'TEAM' OR dependency_type_name = N'Team'
        ORDER  BY dependency_type_id);

    SELECT
        t.team_id                         AS TeamId,
        t.team_name                       AS TeamName,
        t.team_manager_id                 AS TeamManagerId,
        mgr.employee_name                 AS TeamManagerName,
        CAST(CASE WHEN t.team_manager_id IS NOT NULL AND mgr.employee_id IS NOT NULL
                  THEN 1 ELSE 0 END AS BIT) AS HasManager,
        d.department_name                 AS DepartmentName,
        t.parent_department_id            AS DepartmentId,
        CAST(CASE WHEN @practice_id IS NULL THEN 0
                  WHEN EXISTS (
                      SELECT 1
                      FROM   grac_practice.practice_dependency_resolution r
                      JOIN   grac_practice.practice_instance pi
                             ON pi.practice_instance_id = r.practice_instance_id
                      WHERE  pi.practice_id            = @practice_id
                        AND  r.organization_id         = @organization_id
                        AND  r.dependency_type_id      = @team_type_id
                        AND  r.resolved_dependency_id  = t.team_id
                        AND  r.is_active               = 1
                        AND  pi.status                 = N'Active')
                  THEN 1 ELSE 0 END AS BIT) AS AlreadyConfigured,
        (SELECT TOP 1 pi.instance_code
         FROM   grac_practice.practice_dependency_resolution r
         JOIN   grac_practice.practice_instance pi
                ON pi.practice_instance_id = r.practice_instance_id
         WHERE  pi.practice_id            = @practice_id
           AND  r.dependency_type_id      = @team_type_id
           AND  r.resolved_dependency_id  = t.team_id
           AND  r.is_active               = 1
         ORDER  BY pi.practice_instance_id) AS ExistingInstanceCode
    FROM   grac_practice.organization_team t
    -- Active-ness is read from record_status_id, exactly as sp_org_team_list
    -- and the monolith's teams branch do. organization_team.status carries a
    -- DEFAULT of 'Active' but nothing on the save path maintains it -- the
    -- forms post statusId -- so filtering on that text column silently
    -- returns nothing.
    JOIN       grac_practice.record_status_master rs
           ON rs.record_status_id = t.record_status_id
    LEFT   JOIN grac_practice.organization_employee mgr
           ON mgr.employee_id      = t.team_manager_id
          AND mgr.organization_id  = t.organization_id
    LEFT   JOIN grac_practice.organization_department d
           ON d.department_id = t.parent_department_id
    WHERE  t.organization_id = @organization_id
      AND (rs.status_code = N'ACTIVE' OR rs.status_name = N'Active')
    ORDER  BY t.team_name;
END
GO

-- =====================================================================
-- 3. sp_practice_instance_configure
--
--    @team_ids_json is a JSON array of team ids: [3,7,11]
--
--    Returns one row per requested team with the outcome, so the caller
--    can report honestly instead of claiming a blanket success.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_practice_instance_configure
    @organization_id BIGINT,
    @practice_id     BIGINT,
    @team_ids_json   NVARCHAR(MAX),
    @actor           NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @organization_id IS NULL OR @practice_id IS NULL
        THROW 52503, 'sp_practice_instance_configure: organization_id and practice_id are required.', 1;

    IF @team_ids_json IS NULL OR ISJSON(@team_ids_json) <> 1
        THROW 52504, 'sp_practice_instance_configure: team_ids_json must be a JSON array of team ids.', 1;

    DECLARE @practice_name NVARCHAR(300);
    SELECT @practice_name = practice_name
    FROM   grac_practice.practice
    WHERE  practice_id = @practice_id AND organization_id = @organization_id;

    IF @practice_name IS NULL
        THROW 52505, 'sp_practice_instance_configure: practice not found for this organization.', 1;

    DECLARE @team_type_id INT = (
        SELECT TOP 1 dependency_type_id
        FROM   grac_practice.dependency_type_master
        WHERE  dependency_type_code = N'TEAM' OR dependency_type_name = N'Team'
        ORDER  BY dependency_type_id);
    IF @team_type_id IS NULL
        THROW 52506, 'sp_practice_instance_configure: Team dependency type is missing.', 1;

    DECLARE @active_record_status_id INT = (
        SELECT TOP 1 record_status_id FROM grac_practice.record_status_master
        WHERE status_code = 'ACTIVE' OR status_name = 'Active' ORDER BY record_status_id);
    IF @active_record_status_id IS NULL
        THROW 52507, 'sp_practice_instance_configure: record status master data is missing.', 1;

    -- A newly configured instance has not been implemented yet. The seeded
    -- vocabulary (043) is Not Implemented / Partially Implemented /
    -- Implemented / N-A -- there is no "Not Started" or "Active", so ask for
    -- Not Implemented by name and fall back to the lowest display_order
    -- rather than assuming a code that may not be there.
    DECLARE @impl_status_id INT, @impl_status_name NVARCHAR(120);

    SELECT TOP 1 @impl_status_id = implementation_status_id, @impl_status_name = status_name
    FROM   grac_practice.implementation_status_master
    WHERE  is_active = 1
      AND (status_code = N'Not Implemented' OR status_name = N'Not Implemented')
    ORDER  BY implementation_status_id;

    IF @impl_status_id IS NULL
        SELECT TOP 1 @impl_status_id = implementation_status_id, @impl_status_name = status_name
        FROM   grac_practice.implementation_status_master
        WHERE  is_active = 1
        ORDER  BY display_order, implementation_status_id;

    IF @impl_status_id IS NULL
        THROW 52508, 'sp_practice_instance_configure: implementation status master data is missing.', 1;

    DECLARE @resolved_status_id INT = (
        SELECT TOP 1 resolution_status_id FROM grac_practice.dependency_resolution_status_master
        WHERE status_code = N'Resolved' ORDER BY resolution_status_id);
    IF @resolved_status_id IS NULL
        THROW 52509, 'sp_practice_instance_configure: Resolved dependency status is missing.', 1;

    -- practice_instance_dependency.criticality_id is NOT NULL (migration 016
    -- tightened it), so it has to be resolved rather than left to a default.
    -- Medium by name, falling back to the lowest display_order so a renamed
    -- catalog does not break the insert.
    DECLARE @criticality_id INT, @criticality_name NVARCHAR(80);

    SELECT TOP 1 @criticality_id = criticality_id, @criticality_name = criticality_name
    FROM   grac_practice.criticality_master
    WHERE  is_active = 1
      AND (criticality_code = N'Medium' OR criticality_name = N'Medium')
    ORDER  BY criticality_id;

    IF @criticality_id IS NULL
        SELECT TOP 1 @criticality_id = criticality_id, @criticality_name = criticality_name
        FROM   grac_practice.criticality_master
        WHERE  is_active = 1
        ORDER  BY display_order, criticality_id;

    IF @criticality_id IS NULL
        THROW 52511, 'sp_practice_instance_configure: criticality master data is missing.', 1;

    -- ---------------------------------------------------------------
    -- Gather the requested teams and classify them BEFORE writing.
    -- ---------------------------------------------------------------
    DECLARE @work TABLE (
        TeamId              BIGINT PRIMARY KEY,
        TeamName            NVARCHAR(200) NULL,
        ManagerId           BIGINT NULL,
        ManagerName         NVARCHAR(200) NULL,
        DepartmentId        BIGINT NULL,
        DepartmentName      NVARCHAR(200) NULL,
        Outcome             NVARCHAR(40) NOT NULL,
        PracticeInstanceId  BIGINT NULL,
        InstanceCode        NVARCHAR(100) NULL,
        InstanceName        NVARCHAR(300) NULL
    );

    INSERT INTO @work (TeamId, TeamName, ManagerId, ManagerName, DepartmentId, DepartmentName, Outcome)
    SELECT DISTINCT
           j.TeamId,
           t.team_name,
           CASE WHEN mgr.employee_id IS NOT NULL THEN t.team_manager_id END,
           mgr.employee_name,
           t.parent_department_id,
           d.department_name,
           CASE
             WHEN t.team_id IS NULL THEN N'TeamNotFound'
             WHEN EXISTS (
                 SELECT 1
                 FROM   grac_practice.practice_dependency_resolution r
                 JOIN   grac_practice.practice_instance pi
                        ON pi.practice_instance_id = r.practice_instance_id
                 WHERE  pi.practice_id           = @practice_id
                   AND  r.dependency_type_id     = @team_type_id
                   AND  r.resolved_dependency_id = t.team_id
                   AND  r.is_active              = 1
                   AND  pi.status                = N'Active')
                  THEN N'AlreadyConfigured'
             ELSE N'Pending'
           END
    FROM   OPENJSON(@team_ids_json) WITH (TeamId BIGINT '$') j
    -- Same active-ness test as sp_practice_team_option_list, so a team the
    -- picker offered can never come back here as TeamNotFound.
    LEFT   JOIN grac_practice.organization_team t
           ON t.team_id         = j.TeamId
          AND t.organization_id = @organization_id
          AND EXISTS (SELECT 1 FROM grac_practice.record_status_master rs
                       WHERE rs.record_status_id = t.record_status_id
                         AND (rs.status_code = N'ACTIVE' OR rs.status_name = N'Active'))
    LEFT   JOIN grac_practice.organization_employee mgr
           ON mgr.employee_id     = t.team_manager_id
          AND mgr.organization_id = t.organization_id
    LEFT   JOIN grac_practice.organization_department d
           ON d.department_id = t.parent_department_id;

    IF NOT EXISTS (SELECT 1 FROM @work)
        THROW 52510, 'sp_practice_instance_configure: no teams were supplied.', 1;

    -- ---------------------------------------------------------------
    -- Allocate codes and write. One transaction: an instance without its
    -- Team dependency resolved is worse than no instance at all, because
    -- it looks configured while failing every eligibility check.
    -- ---------------------------------------------------------------
    BEGIN TRAN;

    DECLARE @team_id BIGINT, @team_name NVARCHAR(200), @manager_id BIGINT,
            @manager_name NVARCHAR(200), @department_id BIGINT, @department_name NVARCHAR(200),
            @code NVARCHAR(100), @name NVARCHAR(300), @next INT, @new_id BIGINT;

    -- Highest PR_nnn already used in this organization. UPDLOCK/HOLDLOCK so
    -- two people pressing Configure at the same moment cannot both read the
    -- same maximum and then collide on uq_pm_practice_instance.
    SELECT @next = ISNULL(MAX(TRY_CONVERT(INT, SUBSTRING(instance_code, 4, 20))), 0) + 1
    FROM   grac_practice.practice_instance WITH (UPDLOCK, HOLDLOCK)
    WHERE  organization_id = @organization_id
      AND  instance_code LIKE N'PR[_]%'
      AND  TRY_CONVERT(INT, SUBSTRING(instance_code, 4, 20)) IS NOT NULL;

    DECLARE team_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT TeamId, TeamName, ManagerId, ManagerName, DepartmentId, DepartmentName
        FROM   @work WHERE Outcome = N'Pending' ORDER BY TeamName;

    OPEN team_cursor;
    FETCH NEXT FROM team_cursor
        INTO @team_id, @team_name, @manager_id, @manager_name, @department_id, @department_name;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        -- Skip over any code already taken by hand-entered instances.
        SET @code = N'PR_' + FORMAT(@next, '000');
        WHILE EXISTS (SELECT 1 FROM grac_practice.practice_instance
                       WHERE organization_id = @organization_id AND instance_code = @code)
        BEGIN
            SET @next = @next + 1;
            SET @code = N'PR_' + FORMAT(@next, '000');
        END

        SET @name = LEFT(@practice_name + N'-' + @team_name, 300);

        INSERT grac_practice.practice_instance
            (practice_id, organization_id, instance_code, instance_name,
             primary_owner_id, primary_owner, department_id, department,
             assurance_mode, criticality, implementation_status, implementation_status_id,
             status, record_status_id, entered_by)
        VALUES
            (@practice_id, @organization_id, @code, @name,
             @manager_id, @manager_name, @department_id, @department_name,
             N'Manual', N'Medium', @impl_status_name, @impl_status_id,
             N'Active', @active_record_status_id, @actor);

        SET @new_id = SCOPE_IDENTITY();

        -- Declare the Team dependency...
        INSERT grac_practice.practice_instance_dependency
            (organization_id, practice_instance_id, dependency_type_id, dependency_type,
             dependency_name, dependency_reference_id, dependency_source_type,
             owner_name, criticality_id, criticality, status, record_status_id, entered_by)
        VALUES
            (@organization_id, @new_id, @team_type_id, N'Team',
             @team_name, @team_id, N'Team',
             @manager_name, @criticality_id, @criticality_name, N'Active',
             @active_record_status_id, @actor);

        -- ...and resolve it in the same breath. Configure IS the resolution:
        -- the user picked this exact team, so sending them to the Resolve
        -- screen to say so again would be busywork.
        INSERT grac_practice.practice_dependency_resolution
            (organization_id, practice_instance_id, dependency_type_id, dependency_category,
             resolved_dependency_id, resolved_dependency_name, resolution_status_id,
             resolution_status, resolution_owner_id, resolution_dt, is_active,
             record_status_id, entered_by)
        VALUES
            (@organization_id, @new_id, @team_type_id, N'Team',
             @team_id, @team_name, @resolved_status_id,
             N'Resolved', @manager_id, SYSUTCDATETIME(), 1,
             @active_record_status_id, @actor);

        UPDATE @work
           SET Outcome            = N'Created',
               PracticeInstanceId = @new_id,
               InstanceCode       = @code,
               InstanceName       = @name
         WHERE TeamId = @team_id;

        SET @next = @next + 1;

        FETCH NEXT FROM team_cursor
            INTO @team_id, @team_name, @manager_id, @manager_name, @department_id, @department_name;
    END

    CLOSE team_cursor;
    DEALLOCATE team_cursor;

    COMMIT TRAN;

    -- ---------------------------------------------------------------
    -- Result: one row per requested team.
    -- ---------------------------------------------------------------
    SELECT TeamId                                      AS TeamId,
           TeamName                                    AS TeamName,
           Outcome                                     AS Outcome,
           PracticeInstanceId                          AS PracticeInstanceId,
           InstanceCode                                AS InstanceCode,
           InstanceName                                AS InstanceName,
           ManagerName                                 AS OwnerName,
           CAST(CASE WHEN ManagerId IS NULL THEN 0 ELSE 1 END AS BIT) AS HasOwner
    FROM   @work
    ORDER  BY CASE Outcome WHEN N'Created' THEN 0 WHEN N'AlreadyConfigured' THEN 1 ELSE 2 END,
              TeamName;
END
GO

-- =====================================================================
-- Sanity report
-- =====================================================================
SELECT 'sp_practice_detail_get' AS Object_,
       CASE WHEN OBJECT_ID('grac_practice.sp_practice_detail_get','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL SELECT 'sp_practice_team_option_list',
       CASE WHEN OBJECT_ID('grac_practice.sp_practice_team_option_list','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT 'sp_practice_instance_configure',
       CASE WHEN OBJECT_ID('grac_practice.sp_practice_instance_configure','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT 'obligations proc reachable (122)',
       CASE WHEN OBJECT_ID('dbo.sp_pm_view_obligations_typed','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL -- run 122; the practice page shows no obligations without it' END
UNION ALL SELECT 'Team dependency type present',
       CASE WHEN EXISTS (SELECT 1 FROM grac_practice.dependency_type_master
                          WHERE dependency_type_code = N'TEAM' OR dependency_type_name = N'Team')
            THEN 'PASS' ELSE 'FAIL' END;

-- Instance codes already in use per organization, so you can see what the
-- PR_nnn sequence will continue from.
SELECT organization_id                       AS OrganizationId,
       COUNT(*)                              AS TotalInstances,
       SUM(CASE WHEN instance_code LIKE N'PR[_]%' THEN 1 ELSE 0 END) AS PrCodedInstances,
       MAX(CASE WHEN instance_code LIKE N'PR[_]%'
                THEN TRY_CONVERT(INT, SUBSTRING(instance_code, 4, 20)) END) AS HighestPrNumber
FROM   grac_practice.practice_instance
GROUP  BY organization_id
ORDER  BY organization_id;

-- Teams without a manager: these produce instances with no owner, which
-- are not assurance-eligible until an owner is set.
SELECT t.organization_id AS OrganizationId, t.team_id AS TeamId, t.team_name AS TeamName
FROM   grac_practice.organization_team t
JOIN   grac_practice.record_status_master rs ON rs.record_status_id = t.record_status_id
WHERE (rs.status_code = N'ACTIVE' OR rs.status_name = N'Active')
  AND (t.team_manager_id IS NULL
       OR NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee e
                       WHERE e.employee_id = t.team_manager_id
                         AND e.organization_id = t.organization_id))
ORDER  BY t.organization_id, t.team_name;

PRINT '139 Practice Configure procedures created.';
PRINT 'Any team listed above will produce an instance with no owner.';
GO
