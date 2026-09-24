-- =====================================================================
-- 266 Risk Centre — dependency mapping procedures, all categories
--
-- Replaces 262's asset-only set. Same shapes, same guarantees, same
-- removal arithmetic -- widened from one category to whatever
-- dependency_type_master holds.
--
-- ---------------------------------------------------------------------
-- THE INHERITANCE CHAIN, AND THE ONE LINE THAT WAS WRONG
-- ---------------------------------------------------------------------
--   Risk -> Practice -> practice_instance -> practice_dependency_resolution
--
-- That is the chain Operationalize writes when a user maps dependencies
-- on a practice instance, and it is category-agnostic:
-- practice_dependency_resolution carries dependency_type_id and
-- resolved_dependency_id for EVERY category, not just assets.
--
-- 262's fn_risk_practice_assets added
--
--     JOIN dependency_type_master dt ... AND dt.dependency_type_code = N'Asset'
--
-- and that single predicate is the whole bug. fn_risk_practice_dependencies
-- below is the same query with the predicate removed and the category
-- carried out instead of discarded.
--
-- ---------------------------------------------------------------------
-- WHAT THIS FILE DELIBERATELY DOES NOT DO
-- ---------------------------------------------------------------------
-- It does NOT provide a "list the objects I can pick for category N"
-- procedure.
--
-- Operationalize already has one, and it is not a stored procedure: the
-- picker posts to `dependency-options/query` on the repository gateway,
-- which reads dependency_type_source_config and builds the query for
-- whichever table that category names. Writing a Risk Centre equivalent
-- would mean a second implementation of "what objects exist for a
-- category", and the two would drift the first time somebody added a
-- source config column.
--
-- So Risk Analysis calls the SAME endpoint the Operationalize picker
-- calls. This file supplies only what is risk-specific: which categories
-- exist (straight from dependency_type_master), and what is already
-- mapped to this risk.
--
-- CONTENTS
--   1. fn_risk_practice_dependencies    inline TVF, all categories
--   2. sp_risk_mapping_sync_primary     REWRITE -- unchanged logic
--   3. sp_risk_practice_map             REWRITE -- inherits every category
--   4. sp_risk_practice_unmap           REWRITE -- dependency-shaped
--   5. sp_risk_dependency_map_direct    NEW  (replaces sp_risk_asset_map_direct)
--   6. sp_risk_dependency_unmap         NEW  (replaces sp_risk_asset_unmap)
--   7. sp_risk_mapping_get              REWRITE -- grouped by category
--   8. sp_risk_mapping_options          REWRITE -- categories, not objects
--   9. Drop 262's asset-only procedures
--
-- ERROR CODE RANGE: 56660-56699
-- Rollback: database/266_risk_dependency_procs_rollback.sql
-- Depends:  002, 261, 262 (dropped here), 265
-- Docs:     docs/risk-centre.md
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

DECLARE @ok BIT = 1;

IF OBJECT_ID('grac_practice.risk_dependency_map','U') IS NULL
BEGIN PRINT 'ABORT (266): risk_dependency_map missing -- run 265 first.'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.risk_dependency_map_source','U') IS NULL
BEGIN PRINT 'ABORT (266): risk_dependency_map_source missing -- run 265 first.'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.risk_practice_map','U') IS NULL
BEGIN PRINT 'ABORT (266): risk_practice_map missing -- run 261 first.'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.practice_dependency_resolution','U') IS NULL
BEGIN PRINT 'ABORT (266): practice_dependency_resolution missing -- run 002 first.'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.dependency_type_master','U') IS NULL
BEGIN PRINT 'ABORT (266): dependency_type_master missing -- run 002 first.'; SET @ok = 0; END

IF @ok = 0
BEGIN
    RAISERROR('266_risk_dependency_procs: prerequisites missing -- see PRINT messages above.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. fn_risk_practice_dependencies
--
-- Every dependency a practice carries, in every category, as
-- Operationalize resolved it.
--
-- Compared with 262's fn_risk_practice_assets:
--   * the dependency_type_code = 'Asset' filter is GONE
--   * dependency_type_id / name are carried out instead of discarded
--   * the join to organization_dependency_asset is GONE -- the object
--     name comes from practice_dependency_resolution's own frozen
--     resolved_dependency_name, which is what Operationalize wrote and
--     the only name available across nine different source tables
--
-- Still a UNION across the practice's ACTIVE instances, still DISTINCT
-- per object: a practice with three regional instances depending on the
-- same vendor contributes that vendor once.
--
-- Inline TVF, not a procedure -- it expands into the calling query, so
-- the insert, the delete and the read paths share one definition and
-- still produce single set-based plans. 262's header makes the same
-- argument and 266's sanity check still asserts the 'IF' type.
-- =====================================================================
CREATE OR ALTER FUNCTION grac_practice.fn_risk_practice_dependencies
(
    @organization_id BIGINT,
    @practice_id     BIGINT
)
RETURNS TABLE
AS
RETURN
(
    SELECT r.dependency_type_id                  AS DependencyTypeId,
           MIN(dt.dependency_type_name)          AS DependencyTypeName,
           r.resolved_dependency_id              AS DependencyObjectId,
           MIN(r.resolved_dependency_name)       AS DependencyObjectName,
           MIN(pi.practice_instance_id)          AS PracticeInstanceId,
           MIN(r.resolution_id)                  AS ResolutionId
      FROM grac_practice.practice_instance pi
      JOIN grac_practice.practice_dependency_resolution r
        ON r.practice_instance_id = pi.practice_instance_id
       AND r.is_active = 1
      JOIN grac_practice.dependency_type_master dt
        ON dt.dependency_type_id = r.dependency_type_id
       AND dt.is_active = 1
     WHERE pi.practice_id      = @practice_id
       AND pi.organization_id  = @organization_id
       AND pi.status = N'Active'
       AND r.organization_id   = @organization_id
       AND r.resolved_dependency_id IS NOT NULL
     GROUP BY r.dependency_type_id, r.resolved_dependency_id
);
GO

-- =====================================================================
-- 2. sp_risk_mapping_sync_primary   (REWRITE -- logic unchanged)
--
-- Byte-for-byte 262's behaviour: mirror risk_register.linked_practice_id
-- into risk_practice_map as the single 'Primary' row, idempotently,
-- demoting rather than deleting a superseded Primary. Re-emitted only
-- because it delegates to sp_risk_practice_map, which is rewritten below.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_mapping_sync_primary
    @risk_register_id    BIGINT,
    @actor_employee_id   BIGINT        = NULL,
    @caller_display_name NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;

    IF @risk_register_id IS NULL
        THROW 56660, 'sp_risk_mapping_sync_primary: risk_register_id is required.', 1;

    DECLARE @org_id BIGINT, @practice_id BIGINT;
    SELECT @org_id = organization_id, @practice_id = linked_practice_id
      FROM grac_practice.risk_register
     WHERE risk_register_id = @risk_register_id;

    IF @org_id IS NULL
        THROW 56661, 'sp_risk_mapping_sync_primary: risk not found.', 1;

    IF @practice_id IS NULL
    BEGIN
        SELECT CAST(0 AS BIT) AS Created, CAST(NULL AS BIGINT) AS PracticeId;
        RETURN;
    END

    IF EXISTS (SELECT 1 FROM grac_practice.risk_practice_map
                WHERE risk_register_id = @risk_register_id
                  AND practice_id      = @practice_id
                  AND map_source_code  = N'Primary')
    BEGIN
        SELECT CAST(0 AS BIT) AS Created, @practice_id AS PracticeId;
        RETURN;
    END

    UPDATE grac_practice.risk_practice_map
       SET map_source_code = N'Additional',
           updated_by      = @caller_display_name,
           updated_dt      = SYSUTCDATETIME()
     WHERE risk_register_id = @risk_register_id
       AND map_source_code  = N'Primary'
       AND practice_id     <> @practice_id;

    IF EXISTS (SELECT 1 FROM grac_practice.risk_practice_map
                WHERE risk_register_id = @risk_register_id
                  AND practice_id      = @practice_id)
    BEGIN
        UPDATE grac_practice.risk_practice_map
           SET map_source_code = N'Primary',
               updated_by      = @caller_display_name,
               updated_dt      = SYSUTCDATETIME()
         WHERE risk_register_id = @risk_register_id
           AND practice_id      = @practice_id;

        SELECT CAST(0 AS BIT) AS Created, @practice_id AS PracticeId;
        RETURN;
    END

    EXEC grac_practice.sp_risk_practice_map
         @risk_register_id    = @risk_register_id,
         @practice_id         = @practice_id,
         @map_source_code     = N'Primary',
         @actor_employee_id   = @actor_employee_id,
         @caller_display_name = @caller_display_name;
END;
GO

-- =====================================================================
-- 3. sp_risk_practice_map   (REWRITE -- inherits EVERY category)
--
-- Map a practice to a risk and inherit everything Operationalize
-- resolved against it: applications, tools, vendors, assets, processes,
-- locations, people, teams, committees -- whatever
-- dependency_type_master holds, without naming any of them.
--
-- Still idempotent at all three grains (the practice row, the dependency
-- rows, the contribution rows), still two guarded INSERTs rather than a
-- MERGE with OUTPUT ... INTO -- see 262's header for why.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_practice_map
    @risk_register_id    BIGINT,
    @practice_id         BIGINT,
    @map_source_code     NVARCHAR(20)   = N'Additional',
    @remarks             NVARCHAR(1000) = NULL,
    @actor_employee_id   BIGINT         = NULL,
    @caller_display_name NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;

    IF @risk_register_id IS NULL
        THROW 56662, 'sp_risk_practice_map: risk_register_id is required.', 1;
    IF @practice_id IS NULL
        THROW 56663, 'sp_risk_practice_map: practice_id is required.', 1;
    IF @map_source_code NOT IN (N'Primary', N'Additional')
        SET @map_source_code = N'Additional';

    DECLARE @org_id BIGINT, @status NVARCHAR(30);
    SELECT @org_id = organization_id, @status = status_code
      FROM grac_practice.risk_register
     WHERE risk_register_id = @risk_register_id;

    IF @org_id IS NULL
        THROW 56664, 'sp_risk_practice_map: risk not found.', 1;
    IF @status IN (N'Closed', N'Retired')
        THROW 56665, 'sp_risk_practice_map: this risk is closed or retired -- reopen it before changing its practice mapping.', 1;

    DECLARE @p_org BIGINT, @p_name NVARCHAR(300), @p_code NVARCHAR(100);
    SELECT @p_org  = organization_id, @p_name = practice_name, @p_code = practice_code
      FROM grac_practice.practice
     WHERE practice_id = @practice_id;

    IF @p_org IS NULL
        THROW 56666, 'sp_risk_practice_map: practice not found.', 1;
    IF @p_org <> @org_id
        THROW 56667, 'sp_risk_practice_map: that practice belongs to a different organisation.', 1;

    DECLARE @active_rs INT = (
        SELECT TOP 1 record_status_id FROM grac_practice.record_status_master
         WHERE status_code = N'Active' OR status_code = N'ACTIVE' OR status_name = N'Active'
         ORDER BY record_status_id);
    IF @active_rs IS NULL SET @active_rs = 1;

    DECLARE @created BIT = 0, @deps_added INT = 0, @sources_added INT = 0;

    BEGIN TRY
        BEGIN TRAN;

        -- ---- 3a. The practice row --------------------------------
        IF NOT EXISTS (SELECT 1 FROM grac_practice.risk_practice_map
                        WHERE risk_register_id = @risk_register_id
                          AND practice_id      = @practice_id)
        BEGIN
            INSERT INTO grac_practice.risk_practice_map
                (organization_id, risk_register_id, practice_id,
                 practice_name, practice_code, map_source_code,
                 mapped_dt, mapped_by_employee_id, remarks,
                 record_status_id, entered_by, entered_dt)
            VALUES
                (@org_id, @risk_register_id, @practice_id,
                 @p_name, @p_code, @map_source_code,
                 SYSUTCDATETIME(), @actor_employee_id, @remarks,
                 @active_rs, @caller_display_name, SYSUTCDATETIME());

            SET @created = 1;
        END

        -- ---- 3b. Dependencies this risk does not have yet ---------
        -- The NOT EXISTS is keyed on (risk, category, object), so a
        -- vendor already on the risk through another practice is not
        -- inserted again -- "duplicate dependencies are prevented when
        -- the same dependency comes through multiple Practices", with
        -- uq_pm_risk_dependency_map behind it if this guard is ever wrong.
        INSERT INTO grac_practice.risk_dependency_map
            (organization_id, risk_register_id, dependency_type_id, dependency_type_name,
             dependency_object_id, dependency_object_name,
             first_mapped_dt, mapped_by_employee_id,
             record_status_id, entered_by, entered_dt)
        SELECT @org_id, @risk_register_id, pd.DependencyTypeId, pd.DependencyTypeName,
               pd.DependencyObjectId, pd.DependencyObjectName,
               SYSUTCDATETIME(), @actor_employee_id,
               @active_rs, @caller_display_name, SYSUTCDATETIME()
          FROM grac_practice.fn_risk_practice_dependencies(@org_id, @practice_id) pd
         WHERE NOT EXISTS (
                 SELECT 1 FROM grac_practice.risk_dependency_map m
                  WHERE m.risk_register_id     = @risk_register_id
                    AND m.dependency_type_id   = pd.DependencyTypeId
                    AND m.dependency_object_id = pd.DependencyObjectId);

        SET @deps_added = @@ROWCOUNT;

        -- ---- 3c. Contribution rows -------------------------------
        -- Written for EVERY dependency the practice reaches, including
        -- ones already on the risk. That is what makes un-mapping safe.
        INSERT INTO grac_practice.risk_dependency_map_source
            (risk_dependency_map_id, source_kind_code, practice_id,
             practice_instance_id, resolution_id,
             added_dt, added_by_employee_id, entered_by, entered_dt)
        SELECT m.risk_dependency_map_id, N'PracticeDependency', @practice_id,
               pd.PracticeInstanceId, pd.ResolutionId,
               SYSUTCDATETIME(), @actor_employee_id,
               @caller_display_name, SYSUTCDATETIME()
          FROM grac_practice.fn_risk_practice_dependencies(@org_id, @practice_id) pd
          JOIN grac_practice.risk_dependency_map m
            ON m.risk_register_id     = @risk_register_id
           AND m.dependency_type_id   = pd.DependencyTypeId
           AND m.dependency_object_id = pd.DependencyObjectId
         WHERE NOT EXISTS (
                 SELECT 1 FROM grac_practice.risk_dependency_map_source s
                  WHERE s.risk_dependency_map_id = m.risk_dependency_map_id
                    AND s.source_kind_code       = N'PracticeDependency'
                    AND s.practice_id            = @practice_id);

        SET @sources_added = @@ROWCOUNT;

        IF @created = 1 OR @deps_added > 0
            INSERT INTO grac_practice.risk_register_history
                (risk_register_id, action_code, from_status_code, to_status_code,
                 remark, actor_employee_id, actor_display_name, entered_by, entered_dt)
            VALUES
                (@risk_register_id, N'PracticeMapped', @status, @status,
                 CONCAT(N'Practice ', ISNULL(@p_name, CAST(@practice_id AS NVARCHAR(20))),
                        N' mapped as ', @map_source_code, N'. ',
                        CAST(@deps_added AS NVARCHAR(10)),
                        N' dependency(ies) newly in scope, across all Operationalize categories.'),
                 @actor_employee_id, @caller_display_name,
                 @caller_display_name, SYSUTCDATETIME());

        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH

    SELECT @risk_register_id AS RiskRegisterId,
           @practice_id      AS PracticeId,
           @p_name           AS PracticeName,
           @created          AS Created,
           @deps_added       AS DependenciesAdded,
           @sources_added    AS ContributionsAdded;
END;
GO

-- =====================================================================
-- 4. sp_risk_practice_unmap   (REWRITE -- dependency-shaped)
--
-- Identical arithmetic to 262, one table wider:
--   1. delete THIS practice's contribution rows
--   2. delete dependency rows that now have NO contributions at all
--
-- A dependency another mapped practice still reaches keeps that
-- practice's contribution. One mapped directly keeps its Direct
-- contribution. Neither is removed, and no procedure has to reason
-- about why.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_practice_unmap
    @risk_register_id    BIGINT,
    @practice_id         BIGINT,
    @actor_employee_id   BIGINT        = NULL,
    @caller_display_name NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;

    IF @risk_register_id IS NULL
        THROW 56668, 'sp_risk_practice_unmap: risk_register_id is required.', 1;
    IF @practice_id IS NULL
        THROW 56669, 'sp_risk_practice_unmap: practice_id is required.', 1;

    DECLARE @org_id BIGINT, @status NVARCHAR(30);
    SELECT @org_id = organization_id, @status = status_code
      FROM grac_practice.risk_register
     WHERE risk_register_id = @risk_register_id;

    IF @org_id IS NULL
        THROW 56670, 'sp_risk_practice_unmap: risk not found.', 1;
    IF @status IN (N'Closed', N'Retired')
        THROW 56671, 'sp_risk_practice_unmap: this risk is closed or retired -- reopen it before changing its practice mapping.', 1;

    DECLARE @map_source NVARCHAR(20), @p_name NVARCHAR(300);
    SELECT @map_source = map_source_code, @p_name = practice_name
      FROM grac_practice.risk_practice_map
     WHERE risk_register_id = @risk_register_id
       AND practice_id      = @practice_id;

    IF @map_source IS NULL
    BEGIN
        SELECT @risk_register_id AS RiskRegisterId, @practice_id AS PracticeId,
               CAST(0 AS BIT) AS Removed, 0 AS DependenciesRemoved, 0 AS DependenciesKept;
        RETURN;
    END

    IF @map_source = N'Primary'
        THROW 56672, 'sp_risk_practice_unmap: this is the risk''s primary practice. Change the risk''s linked practice instead of unmapping it here.', 1;

    DECLARE @removed INT = 0, @kept INT = 0;

    BEGIN TRY
        BEGIN TRAN;

        DELETE s
          FROM grac_practice.risk_dependency_map_source s
          JOIN grac_practice.risk_dependency_map m
            ON m.risk_dependency_map_id = s.risk_dependency_map_id
         WHERE m.risk_register_id = @risk_register_id
           AND s.source_kind_code = N'PracticeDependency'
           AND s.practice_id      = @practice_id;

        DELETE m
          FROM grac_practice.risk_dependency_map m
         WHERE m.risk_register_id = @risk_register_id
           AND NOT EXISTS (SELECT 1 FROM grac_practice.risk_dependency_map_source s
                            WHERE s.risk_dependency_map_id = m.risk_dependency_map_id);

        SET @removed = @@ROWCOUNT;

        DELETE FROM grac_practice.risk_practice_map
         WHERE risk_register_id = @risk_register_id
           AND practice_id      = @practice_id;

        SELECT @kept = COUNT(*)
          FROM grac_practice.risk_dependency_map
         WHERE risk_register_id = @risk_register_id;

        INSERT INTO grac_practice.risk_register_history
            (risk_register_id, action_code, from_status_code, to_status_code,
             remark, actor_employee_id, actor_display_name, entered_by, entered_dt)
        VALUES
            (@risk_register_id, N'PracticeUnmapped', @status, @status,
             CONCAT(N'Practice ', ISNULL(@p_name, CAST(@practice_id AS NVARCHAR(20))),
                    N' unmapped. ', CAST(@removed AS NVARCHAR(10)),
                    N' dependency(ies) dropped, ', CAST(@kept AS NVARCHAR(10)),
                    N' retained (still reached by another practice or mapped directly).'),
             @actor_employee_id, @caller_display_name,
             @caller_display_name, SYSUTCDATETIME());

        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH

    SELECT @risk_register_id AS RiskRegisterId,
           @practice_id      AS PracticeId,
           CAST(1 AS BIT)    AS Removed,
           @removed          AS DependenciesRemoved,
           @kept             AS DependenciesKept;
END;
GO

-- =====================================================================
-- 5. sp_risk_dependency_map_direct
--
-- Add a dependency in ANY category with no practice involved.
--
-- The object is validated only for existence of its CATEGORY, not of
-- itself: there is no single table to check it against (265, decision 3),
-- and the caller got the id from `dependency-options/query`, which is the
-- same source Operationalize's picker uses and already scopes to the
-- organisation. The frozen name is taken from the caller for the same
-- reason -- it is the label the user actually saw.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_dependency_map_direct
    @risk_register_id      BIGINT,
    @dependency_type_id    INT,
    @dependency_object_id  BIGINT,
    @dependency_object_name NVARCHAR(300) = NULL,
    @remarks               NVARCHAR(1000) = NULL,
    @actor_employee_id     BIGINT        = NULL,
    @caller_display_name   NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;

    IF @risk_register_id IS NULL
        THROW 56673, 'sp_risk_dependency_map_direct: risk_register_id is required.', 1;
    IF @dependency_type_id IS NULL
        THROW 56674, 'sp_risk_dependency_map_direct: dependency_type_id is required.', 1;
    IF @dependency_object_id IS NULL
        THROW 56675, 'sp_risk_dependency_map_direct: dependency_object_id is required.', 1;

    DECLARE @org_id BIGINT, @status NVARCHAR(30);
    SELECT @org_id = organization_id, @status = status_code
      FROM grac_practice.risk_register
     WHERE risk_register_id = @risk_register_id;

    IF @org_id IS NULL
        THROW 56676, 'sp_risk_dependency_map_direct: risk not found.', 1;
    IF @status IN (N'Closed', N'Retired')
        THROW 56677, 'sp_risk_dependency_map_direct: this risk is closed or retired -- reopen it before changing its dependency mapping.', 1;

    DECLARE @type_name NVARCHAR(120);
    SELECT @type_name = dependency_type_name
      FROM grac_practice.dependency_type_master
     WHERE dependency_type_id = @dependency_type_id AND is_active = 1;

    IF @type_name IS NULL
        THROW 56678, 'sp_risk_dependency_map_direct: unknown or inactive dependency category.', 1;

    DECLARE @active_rs INT = (
        SELECT TOP 1 record_status_id FROM grac_practice.record_status_master
         WHERE status_code = N'Active' OR status_code = N'ACTIVE' OR status_name = N'Active'
         ORDER BY record_status_id);
    IF @active_rs IS NULL SET @active_rs = 1;

    DECLARE @map_id BIGINT, @created BIT = 0, @source_added BIT = 0;

    BEGIN TRY
        BEGIN TRAN;

        SELECT @map_id = risk_dependency_map_id
          FROM grac_practice.risk_dependency_map
         WHERE risk_register_id     = @risk_register_id
           AND dependency_type_id   = @dependency_type_id
           AND dependency_object_id = @dependency_object_id;

        IF @map_id IS NULL
        BEGIN
            INSERT INTO grac_practice.risk_dependency_map
                (organization_id, risk_register_id, dependency_type_id, dependency_type_name,
                 dependency_object_id, dependency_object_name,
                 first_mapped_dt, mapped_by_employee_id, remarks,
                 record_status_id, entered_by, entered_dt)
            VALUES
                (@org_id, @risk_register_id, @dependency_type_id, @type_name,
                 @dependency_object_id, @dependency_object_name,
                 SYSUTCDATETIME(), @actor_employee_id, @remarks,
                 @active_rs, @caller_display_name, SYSUTCDATETIME());

            SET @map_id  = SCOPE_IDENTITY();
            SET @created = 1;
        END
        ELSE IF @dependency_object_name IS NOT NULL
            -- The row exists because a practice contributed it. Take the
            -- caller's label if we have one and the stored one is blank,
            -- so a directly confirmed dependency is never left unnamed.
            UPDATE grac_practice.risk_dependency_map
               SET dependency_object_name = COALESCE(dependency_object_name, @dependency_object_name),
                   updated_by = @caller_display_name,
                   updated_dt = SYSUTCDATETIME()
             WHERE risk_dependency_map_id = @map_id;

        IF NOT EXISTS (SELECT 1 FROM grac_practice.risk_dependency_map_source
                        WHERE risk_dependency_map_id = @map_id
                          AND source_kind_code       = N'Direct')
        BEGIN
            INSERT INTO grac_practice.risk_dependency_map_source
                (risk_dependency_map_id, source_kind_code, practice_id,
                 practice_instance_id, resolution_id,
                 added_dt, added_by_employee_id, entered_by, entered_dt)
            VALUES
                (@map_id, N'Direct', NULL, NULL, NULL,
                 SYSUTCDATETIME(), @actor_employee_id,
                 @caller_display_name, SYSUTCDATETIME());

            SET @source_added = 1;
        END

        IF @created = 1 OR @source_added = 1
            INSERT INTO grac_practice.risk_register_history
                (risk_register_id, action_code, from_status_code, to_status_code,
                 remark, actor_employee_id, actor_display_name, entered_by, entered_dt)
            VALUES
                (@risk_register_id, N'DependencyMapped', @status, @status,
                 CONCAT(@type_name, N' ',
                        ISNULL(@dependency_object_name, CAST(@dependency_object_id AS NVARCHAR(20))),
                        N' mapped directly (no practice).'),
                 @actor_employee_id, @caller_display_name,
                 @caller_display_name, SYSUTCDATETIME());

        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH

    SELECT @risk_register_id       AS RiskRegisterId,
           @map_id                 AS RiskDependencyMapId,
           @dependency_type_id     AS DependencyTypeId,
           @type_name              AS DependencyTypeName,
           @dependency_object_id   AS DependencyObjectId,
           @dependency_object_name AS DependencyObjectName,
           @created                AS Created;
END;
GO

-- =====================================================================
-- 6. sp_risk_dependency_unmap
--
-- Removes the DIRECT reason. The map row goes only when no contribution
-- of any kind survives, so a dependency a mapped practice also reaches
-- stays on the risk, relabelled as inherited. Both facts are returned so
-- the screen can say so rather than appearing to ignore the click.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_dependency_unmap
    @risk_register_id     BIGINT,
    @dependency_type_id   INT,
    @dependency_object_id BIGINT,
    @actor_employee_id    BIGINT        = NULL,
    @caller_display_name  NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;

    IF @risk_register_id IS NULL
        THROW 56679, 'sp_risk_dependency_unmap: risk_register_id is required.', 1;
    IF @dependency_type_id IS NULL OR @dependency_object_id IS NULL
        THROW 56680, 'sp_risk_dependency_unmap: dependency_type_id and dependency_object_id are required.', 1;

    DECLARE @org_id BIGINT, @status NVARCHAR(30);
    SELECT @org_id = organization_id, @status = status_code
      FROM grac_practice.risk_register
     WHERE risk_register_id = @risk_register_id;

    IF @org_id IS NULL
        THROW 56681, 'sp_risk_dependency_unmap: risk not found.', 1;
    IF @status IN (N'Closed', N'Retired')
        THROW 56682, 'sp_risk_dependency_unmap: this risk is closed or retired -- reopen it before changing its dependency mapping.', 1;

    DECLARE @map_id BIGINT, @obj_name NVARCHAR(300), @type_name NVARCHAR(120);
    SELECT @map_id = risk_dependency_map_id,
           @obj_name = dependency_object_name,
           @type_name = dependency_type_name
      FROM grac_practice.risk_dependency_map
     WHERE risk_register_id     = @risk_register_id
       AND dependency_type_id   = @dependency_type_id
       AND dependency_object_id = @dependency_object_id;

    IF @map_id IS NULL
    BEGIN
        SELECT @risk_register_id AS RiskRegisterId,
               @dependency_type_id AS DependencyTypeId,
               @dependency_object_id AS DependencyObjectId,
               CAST(0 AS BIT) AS DependencyRemoved, 0 AS RemainingSources;
        RETURN;
    END

    DECLARE @remaining INT = 0, @removed BIT = 0;

    BEGIN TRY
        BEGIN TRAN;

        DELETE FROM grac_practice.risk_dependency_map_source
         WHERE risk_dependency_map_id = @map_id
           AND source_kind_code       = N'Direct';

        SELECT @remaining = COUNT(*)
          FROM grac_practice.risk_dependency_map_source
         WHERE risk_dependency_map_id = @map_id;

        IF @remaining = 0
        BEGIN
            DELETE FROM grac_practice.risk_dependency_map
             WHERE risk_dependency_map_id = @map_id;
            SET @removed = 1;
        END

        INSERT INTO grac_practice.risk_register_history
            (risk_register_id, action_code, from_status_code, to_status_code,
             remark, actor_employee_id, actor_display_name, entered_by, entered_dt)
        VALUES
            (@risk_register_id, N'DependencyUnmapped', @status, @status,
             CONCAT(N'Direct mapping removed for ', ISNULL(@type_name, N'dependency'), N' ',
                    ISNULL(@obj_name, CAST(@dependency_object_id AS NVARCHAR(20))), N'. ',
                    CASE WHEN @removed = 1
                         THEN N'Removed from the risk.'
                         ELSE CONCAT(N'Retained -- still reached by ',
                                     CAST(@remaining AS NVARCHAR(10)),
                                     N' mapped practice(s).') END),
             @actor_employee_id, @caller_display_name,
             @caller_display_name, SYSUTCDATETIME());

        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH

    SELECT @risk_register_id     AS RiskRegisterId,
           @dependency_type_id   AS DependencyTypeId,
           @dependency_object_id AS DependencyObjectId,
           @removed              AS DependencyRemoved,
           @remaining            AS RemainingSources;
END;
GO

-- =====================================================================
-- 7. sp_risk_mapping_get   (REWRITE -- grouped by category)
--
-- THREE result sets now, not two:
--   1. mapped practices
--   2. every ACTIVE category, so the screen can render a section per
--      category exactly as Operationalize does -- including the empty
--      ones, which is how a user discovers a category is available
--   3. mapped dependencies, each carrying its category and provenance
--
-- Result set 2 is the important addition. Deriving the category list
-- from the mapped rows would hide every category with nothing in it, and
-- "you can also map a Vendor here" would be invisible until somebody had
-- already mapped a vendor.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_mapping_get
    @risk_register_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    IF @risk_register_id IS NULL
        THROW 56683, 'sp_risk_mapping_get: risk_register_id is required.', 1;

    DECLARE @org_id BIGINT, @primary_practice_id BIGINT;
    SELECT @org_id = organization_id
      FROM grac_practice.risk_register
     WHERE risk_register_id = @risk_register_id;

    IF @org_id IS NULL
        THROW 56684, 'sp_risk_mapping_get: risk not found.', 1;

    SELECT @primary_practice_id = practice_id
      FROM grac_practice.risk_practice_map
     WHERE risk_register_id = @risk_register_id
       AND map_source_code  = N'Primary';

    -- ---- 1. Mapped practices -------------------------------------
    SELECT pm.risk_practice_map_id       AS RiskPracticeMapId,
           pm.practice_id                AS PracticeId,
           COALESCE(p.practice_name, pm.practice_name) AS PracticeName,
           COALESCE(p.practice_code, pm.practice_code) AS PracticeCode,
           pm.map_source_code            AS MapSourceCode,
           CAST(CASE WHEN pm.map_source_code = N'Primary' THEN 1 ELSE 0 END AS BIT) AS IsPrimary,
           pm.mapped_dt                  AS MappedDt,
           pm.mapped_by_employee_id      AS MappedByEmployeeId,
           e.employee_name               AS MappedByName,
           pm.remarks                    AS Remarks,
           (SELECT COUNT(*)
              FROM grac_practice.risk_dependency_map_source s
              JOIN grac_practice.risk_dependency_map m
                ON m.risk_dependency_map_id = s.risk_dependency_map_id
             WHERE m.risk_register_id = @risk_register_id
               AND s.practice_id      = pm.practice_id) AS DependencyCount
      FROM grac_practice.risk_practice_map pm
      LEFT JOIN grac_practice.practice p ON p.practice_id = pm.practice_id
      LEFT JOIN grac_practice.organization_employee e ON e.employee_id = pm.mapped_by_employee_id
     WHERE pm.risk_register_id = @risk_register_id
     ORDER BY CASE WHEN pm.map_source_code = N'Primary' THEN 0 ELSE 1 END,
              COALESCE(p.practice_name, pm.practice_name);

    -- ---- 2. The categories, from the Operationalize master --------
    -- Ordered by display_order, the same ordering the Operationalize
    -- screen uses, so the two pages list their categories alike.
    SELECT dt.dependency_type_id   AS DependencyTypeId,
           dt.dependency_type_code AS DependencyTypeCode,
           dt.dependency_type_name AS DependencyTypeName,
           dt.display_order        AS DisplayOrder,
           -- Whether objects can be picked for it at all. A category with
           -- no source config is declarable in Operationalize but has
           -- nothing to choose from, and the screen should not offer an
           -- "Add" control that cannot work.
           CAST(CASE WHEN sc.dependency_type_id IS NULL THEN 0 ELSE 1 END AS BIT) AS IsSelectable,
           (SELECT COUNT(*) FROM grac_practice.risk_dependency_map m
             WHERE m.risk_register_id   = @risk_register_id
               AND m.dependency_type_id = dt.dependency_type_id) AS MappedCount
      FROM grac_practice.dependency_type_master dt
      LEFT JOIN grac_practice.dependency_type_source_config sc
             ON sc.dependency_type_id = dt.dependency_type_id
            AND sc.status = N'Active'
     WHERE dt.is_active = 1
     ORDER BY dt.display_order, dt.dependency_type_name;

    -- ---- 3. Mapped dependencies, with provenance ------------------
    -- SourceLabel is resolved HERE, not in the client, for the reason
    -- 262 gave: the label is a rule, and a rule computed in two places
    -- eventually disagrees with itself.
    SELECT m.risk_dependency_map_id     AS RiskDependencyMapId,
           m.dependency_type_id         AS DependencyTypeId,
           COALESCE(dt.dependency_type_name, m.dependency_type_name) AS DependencyTypeName,
           m.dependency_object_id       AS DependencyObjectId,
           m.dependency_object_name     AS DependencyObjectName,
           m.first_mapped_dt            AS FirstMappedDt,
           m.remarks                    AS Remarks,

           CAST(CASE WHEN EXISTS (SELECT 1 FROM grac_practice.risk_dependency_map_source s
                                   WHERE s.risk_dependency_map_id = m.risk_dependency_map_id
                                     AND s.source_kind_code = N'Direct')
                     THEN 1 ELSE 0 END AS BIT) AS IsDirect,
           CAST(CASE WHEN EXISTS (SELECT 1 FROM grac_practice.risk_dependency_map_source s
                                   WHERE s.risk_dependency_map_id = m.risk_dependency_map_id
                                     AND s.source_kind_code = N'PracticeDependency')
                     THEN 1 ELSE 0 END AS BIT) AS IsInherited,
           CAST(CASE WHEN @primary_practice_id IS NOT NULL
                      AND EXISTS (SELECT 1 FROM grac_practice.risk_dependency_map_source s
                                   WHERE s.risk_dependency_map_id = m.risk_dependency_map_id
                                     AND s.practice_id = @primary_practice_id)
                     THEN 1 ELSE 0 END AS BIT) AS FromPrimaryPractice,

           CASE
             WHEN EXISTS (SELECT 1 FROM grac_practice.risk_dependency_map_source s
                           WHERE s.risk_dependency_map_id = m.risk_dependency_map_id
                             AND s.source_kind_code = N'Direct')
              AND EXISTS (SELECT 1 FROM grac_practice.risk_dependency_map_source s
                           WHERE s.risk_dependency_map_id = m.risk_dependency_map_id
                             AND s.source_kind_code = N'PracticeDependency')
                  THEN N'DirectAndInherited'
             WHEN EXISTS (SELECT 1 FROM grac_practice.risk_dependency_map_source s
                           WHERE s.risk_dependency_map_id = m.risk_dependency_map_id
                             AND s.source_kind_code = N'Direct')
                  THEN N'Direct'
             WHEN @primary_practice_id IS NOT NULL
              AND EXISTS (SELECT 1 FROM grac_practice.risk_dependency_map_source s
                           WHERE s.risk_dependency_map_id = m.risk_dependency_map_id
                             AND s.practice_id = @primary_practice_id)
                  THEN N'Primary'
             ELSE N'Additional'
           END                          AS SourceLabel,

           (SELECT COUNT(*) FROM grac_practice.risk_dependency_map_source s
             WHERE s.risk_dependency_map_id = m.risk_dependency_map_id) AS SourceCount,

           (SELECT STRING_AGG(CONVERT(NVARCHAR(MAX),
                       COALESCE(pp.practice_name, pm2.practice_name)), N', ')
              FROM grac_practice.risk_dependency_map_source s2
              LEFT JOIN grac_practice.practice pp ON pp.practice_id = s2.practice_id
              LEFT JOIN grac_practice.risk_practice_map pm2
                     ON pm2.risk_register_id = @risk_register_id
                    AND pm2.practice_id      = s2.practice_id
             WHERE s2.risk_dependency_map_id = m.risk_dependency_map_id
               AND s2.source_kind_code       = N'PracticeDependency') AS SourcePractices
      FROM grac_practice.risk_dependency_map m
      LEFT JOIN grac_practice.dependency_type_master dt
             ON dt.dependency_type_id = m.dependency_type_id
     WHERE m.risk_register_id = @risk_register_id
     ORDER BY dt.display_order, m.dependency_object_name;
END;
GO

-- =====================================================================
-- 8. sp_risk_mapping_options   (REWRITE -- practices only)
--
-- 262 returned mappable practices AND mappable assets. The asset half is
-- GONE, deliberately: the objects for a category come from
-- `dependency-options/query`, the endpoint the Operationalize picker
-- already uses, which reads dependency_type_source_config and can query
-- whichever of the nine tables the category names.
--
-- Reimplementing that here would mean dynamic SQL over a config table
-- that another component already knows how to read -- a second
-- implementation of "what objects exist", guaranteed to drift.
--
-- So this returns only what is genuinely risk-specific: which practices
-- this risk does not already have, and how much each would bring in.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_mapping_options
    @risk_register_id BIGINT,
    @search           NVARCHAR(200) = NULL,
    @top              INT           = 200
AS
BEGIN
    SET NOCOUNT ON;

    IF @risk_register_id IS NULL
        THROW 56685, 'sp_risk_mapping_options: risk_register_id is required.', 1;
    IF @top IS NULL OR @top <= 0 OR @top > 1000 SET @top = 200;

    DECLARE @org_id BIGINT;
    SELECT @org_id = organization_id
      FROM grac_practice.risk_register
     WHERE risk_register_id = @risk_register_id;

    IF @org_id IS NULL
        THROW 56686, 'sp_risk_mapping_options: risk not found.', 1;

    DECLARE @like NVARCHAR(210) =
        CASE WHEN @search IS NULL OR LEN(LTRIM(RTRIM(@search))) = 0
             THEN NULL ELSE N'%' + LTRIM(RTRIM(@search)) + N'%' END;

    SELECT TOP (@top)
           p.practice_id    AS PracticeId,
           p.practice_name  AS PracticeName,
           p.practice_code  AS PracticeCode,
           -- How much mapping this practice would pull in, across every
           -- category. Shown in the picker so "map this practice" is
           -- never a surprise.
           (SELECT COUNT(*) FROM grac_practice.fn_risk_practice_dependencies(@org_id, p.practice_id))
                            AS DependenciesFromPractice
      FROM grac_practice.practice p
     WHERE p.organization_id = @org_id
       AND p.status = N'Active'
       AND (@like IS NULL OR p.practice_name LIKE @like OR p.practice_code LIKE @like)
       AND NOT EXISTS (SELECT 1 FROM grac_practice.risk_practice_map pm
                        WHERE pm.risk_register_id = @risk_register_id
                          AND pm.practice_id      = p.practice_id)
     ORDER BY p.practice_name;
END;
GO

-- =====================================================================
-- 9. Retire 262's asset-only procedures
--
-- Their tables are gone (265), so they cannot work. Dropped rather than
-- left to fail: a procedure that exists and throws "Invalid object name"
-- is harder to diagnose than one that is honestly absent.
-- =====================================================================
IF OBJECT_ID('grac_practice.sp_risk_asset_map_direct','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_risk_asset_map_direct;
GO
IF OBJECT_ID('grac_practice.sp_risk_asset_unmap','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_risk_asset_unmap;
GO
IF OBJECT_ID('grac_practice.fn_risk_practice_assets','IF') IS NOT NULL
    DROP FUNCTION grac_practice.fn_risk_practice_assets;
GO

-- =====================================================================
-- Sanity
-- =====================================================================
SELECT '266 objects present' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.fn_risk_practice_dependencies','IF')  IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_risk_practice_map','P')            IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_risk_practice_unmap','P')          IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_risk_dependency_map_direct','P')   IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_risk_dependency_unmap','P')        IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_risk_mapping_get','P')             IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_risk_mapping_options','P')         IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_risk_mapping_sync_primary','P')    IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT '266 asset-only objects retired' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.fn_risk_practice_assets','IF')   IS NULL
             AND OBJECT_ID('grac_practice.sp_risk_asset_map_direct','P')   IS NULL
             AND OBJECT_ID('grac_practice.sp_risk_asset_unmap','P')        IS NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT '266 dependency function is inline' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.fn_risk_practice_dependencies','IF') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;

-- The point of the whole migration, asserted: no category is named in
-- the inheritance path. If somebody ever reintroduces a filter, this
-- fails and says so.
SELECT '266 inheritance names no category' AS Check_,
       CASE WHEN NOT EXISTS (SELECT 1 FROM sys.sql_modules
                              WHERE object_id = OBJECT_ID('grac_practice.fn_risk_practice_dependencies')
                                AND (definition LIKE '%dependency_type_code = N''Asset''%'
                                  OR definition LIKE '%dependency_type_code = ''Asset''%'))
            THEN 'PASS' ELSE 'FAIL -- an Asset filter is back in the TVF' END AS Result;

PRINT '266 Risk dependency mapping procedures installed.';
PRINT '     Inheritance now covers EVERY dependency_type_master category,';
PRINT '     exactly as Operationalize resolved them.';
PRINT '     Object pickers use dependency-options/query -- the same endpoint';
PRINT '     the Operationalize picker uses. No second object-list exists.';
GO

SET NOEXEC OFF;
GO
