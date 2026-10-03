-- =====================================================================
-- 387  Risk: map practice INSTANCES; Treatment tasks from mapped
--      instances' gaps; link existing open tasks as treatment work
--
-- REQUEST (sir, 2026-09-27)
-- -------------------------
--   * "Map practice" maps a PRACTICE INSTANCE, not a practice. The shared
--     Practice Picker gains an Instance level (practice-picker.js).
--   * Existing practice-level mappings (Primary included) are converted
--     to instance-level: each becomes the practice's active instance(s)
--     in the organisation. (Confirmed with sir.)
--   * Once an instance is mapped, the tasks raised from THAT instance's
--     gaps appear automatically under "Treatment tasks from Task Board".
--   * "Map open task": an existing open task can be linked to the risk as
--     treatment work.
--   * Both kinds count toward the treatment gate exactly like the risk's
--     own treatment tasks (confirmed with sir): an open one blocks
--     Residual Risk Analysis.
--
-- WHAT THIS DOES
-- --------------
--   1. risk_practice_map: + practice_instance_id (FK), + frozen
--      practice_instance_name / _code, + computed practice_instance_key.
--      Unique (risk, practice) becomes unique (risk, practice, instance)
--      so one practice can be on a risk once per instance. practice_id
--      stays NOT NULL and is always the instance's practice, so every
--      existing reader (counts, context, picker flags) keeps working.
--   2. fn_risk_instance_dependencies -- fn_risk_practice_dependencies
--      narrowed to ONE instance.
--   3. sp_risk_practice_instance_map / _instance_unmap -- map / unmap by
--      instance (unmap by risk_practice_map_id), inheriting / releasing
--      only that instance's dependencies. The practice-level procs (262 /
--      266) are left in place for the Primary sync and old callers.
--   4. sp_risk_practice_map_expand_instances -- turns a practice-level
--      row (instance NULL) into instance rows. Called by the API after
--      the primary sync on every mapping read, and once below for every
--      existing risk (the backfill).
--   5. sp_risk_mapping_sync_primary (354 body) -- promotes exactly one
--      row when a practice has several (unique Primary index).
--   6. sp_risk_mapping_get (267 body) -- + PracticeInstanceId / Name /
--      Code; per-instance DependencyCount; de-duplicated SourcePractices.
--   7. sp_practice_picker_instances -- the picker's new Instance level.
--   8. risk_treatment_task_link + sp_risk_treatment_task_link / _unlink /
--      sp_risk_open_task_list -- "Map open task".
--   9. sp_risk_treatment_state (263 body) -- task set = the risk's own
--      treatment tasks + tasks of gaps raised on mapped instances +
--      linked tasks (each with its sub tasks); new LinkSourceCode column
--      (Treatment / Gap / Linked). Gate arithmetic unchanged.
--
-- Rollback: 387_risk_practice_instance_mapping_rollback.sql
-- DEPENDS ON: 261/265/266/267 (risk mapping), 263 (treatment state),
--   326 (vw_pm_practice_task), 354 (sync body), 282 (picker).
-- Re-runnable: yes. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

DECLARE @ok BIT = 1;
IF OBJECT_ID('grac_practice.risk_practice_map','U') IS NULL
BEGIN PRINT 'ABORT (387): risk_practice_map missing (261).'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.risk_dependency_map_source','U') IS NULL
BEGIN PRINT 'ABORT (387): risk_dependency_map_source missing (265).'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.fn_risk_practice_dependencies','IF') IS NULL
BEGIN PRINT 'ABORT (387): fn_risk_practice_dependencies missing (266/267).'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.vw_pm_practice_task','V') IS NULL
BEGIN PRINT 'ABORT (387): vw_pm_practice_task missing (326).'; SET @ok = 0; END
IF @ok = 0
BEGIN
    RAISERROR('387_risk_practice_instance_mapping: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. risk_practice_map: instance columns + uniqueness per instance
-- =====================================================================
IF COL_LENGTH('grac_practice.risk_practice_map','practice_instance_id') IS NULL
    ALTER TABLE grac_practice.risk_practice_map
        ADD practice_instance_id BIGINT NULL
            CONSTRAINT fk_pm_risk_practice_map_instance
                REFERENCES grac_practice.practice_instance(practice_instance_id);
GO
IF COL_LENGTH('grac_practice.risk_practice_map','practice_instance_name') IS NULL
    ALTER TABLE grac_practice.risk_practice_map ADD practice_instance_name NVARCHAR(300) NULL;
GO
IF COL_LENGTH('grac_practice.risk_practice_map','practice_instance_code') IS NULL
    ALTER TABLE grac_practice.risk_practice_map ADD practice_instance_code NVARCHAR(100) NULL;
GO
IF COL_LENGTH('grac_practice.risk_practice_map','practice_instance_key') IS NULL
    ALTER TABLE grac_practice.risk_practice_map
        ADD practice_instance_key AS (ISNULL(practice_instance_id, CAST(0 AS BIGINT))) PERSISTED;
GO
IF EXISTS (SELECT 1 FROM sys.key_constraints
            WHERE name = 'uq_pm_risk_practice_map'
              AND parent_object_id = OBJECT_ID('grac_practice.risk_practice_map'))
    ALTER TABLE grac_practice.risk_practice_map DROP CONSTRAINT uq_pm_risk_practice_map;
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes
                WHERE name = 'ux_pm_risk_practice_map_instance'
                  AND object_id = OBJECT_ID('grac_practice.risk_practice_map'))
    CREATE UNIQUE INDEX ux_pm_risk_practice_map_instance
        ON grac_practice.risk_practice_map(risk_register_id, practice_id, practice_instance_key);
GO
PRINT '387: risk_practice_map is instance-aware.';
GO

-- =====================================================================
-- 2. fn_risk_instance_dependencies
-- =====================================================================
CREATE OR ALTER FUNCTION grac_practice.fn_risk_instance_dependencies
(
    @organization_id      BIGINT,
    @practice_instance_id BIGINT
)
RETURNS TABLE
AS
RETURN
(
    SELECT r.dependency_type_id                  AS DependencyTypeId,
           MIN(dt.dependency_type_name)          AS DependencyTypeName,
           r.resolved_dependency_id              AS DependencyObjectId,
           MIN(r.resolved_dependency_name)       AS DependencyObjectName,
           MIN(pi.practice_id)                   AS PracticeId,
           MIN(pi.practice_instance_id)          AS PracticeInstanceId,
           MIN(r.resolution_id)                  AS ResolutionId
      FROM grac_practice.practice_instance pi
      JOIN grac_practice.practice_dependency_resolution r
        ON r.practice_instance_id = pi.practice_instance_id
       AND r.is_active = 1
      JOIN grac_practice.dependency_type_master dt
        ON dt.dependency_type_id = r.dependency_type_id
       AND dt.is_active = 1
       AND dt.is_dependency_mappable = 1
     WHERE pi.practice_instance_id = @practice_instance_id
       AND pi.organization_id      = @organization_id
       AND r.organization_id       = @organization_id
       AND r.resolved_dependency_id IS NOT NULL
     GROUP BY r.dependency_type_id, r.resolved_dependency_id
);
GO

-- =====================================================================
-- 3a. sp_risk_practice_instance_map
--     Maps ONE instance. If the risk already carries a practice-level row
--     (instance NULL) for the same practice, that row is CLAIMED for this
--     instance instead of adding a second row -- that is how the Primary
--     row becomes instance-level without losing its Primary status.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_practice_instance_map
    @risk_register_id     BIGINT,
    @practice_instance_id BIGINT,
    @map_source_code      NVARCHAR(20)   = N'Additional',
    @remarks              NVARCHAR(1000) = NULL,
    @actor_employee_id    BIGINT         = NULL,
    @caller_display_name  NVARCHAR(100)  = N'system',
    @suppress_result      BIT            = 0
AS
BEGIN
    SET NOCOUNT ON;

    IF @risk_register_id IS NULL
        THROW 56760, 'sp_risk_practice_instance_map: risk_register_id is required.', 1;
    IF @practice_instance_id IS NULL
        THROW 56761, 'sp_risk_practice_instance_map: practice_instance_id is required.', 1;
    IF @map_source_code NOT IN (N'Primary', N'Additional')
        SET @map_source_code = N'Additional';

    DECLARE @org_id BIGINT, @status NVARCHAR(30);
    SELECT @org_id = organization_id, @status = status_code
      FROM grac_practice.risk_register
     WHERE risk_register_id = @risk_register_id;

    IF @org_id IS NULL
        THROW 56762, 'sp_risk_practice_instance_map: risk not found.', 1;
    IF @status IN (N'Closed', N'Retired')
        THROW 56763, 'sp_risk_practice_instance_map: this risk is closed or retired -- reopen it before changing its practice mapping.', 1;

    DECLARE @practice_id BIGINT, @i_org BIGINT, @i_name NVARCHAR(300), @i_code NVARCHAR(100),
            @p_name NVARCHAR(300), @p_code NVARCHAR(100);
    SELECT @practice_id = pi.practice_id, @i_org = pi.organization_id,
           @i_name = pi.instance_name, @i_code = pi.instance_code,
           @p_name = p.practice_name,  @p_code = p.practice_code
      FROM grac_practice.practice_instance pi
      JOIN grac_practice.practice p ON p.practice_id = pi.practice_id
     WHERE pi.practice_instance_id = @practice_instance_id;

    IF @practice_id IS NULL
        THROW 56764, 'sp_risk_practice_instance_map: practice instance not found.', 1;
    IF @i_org <> @org_id
        THROW 56765, 'sp_risk_practice_instance_map: that practice instance belongs to a different organisation.', 1;

    DECLARE @active_rs INT = (
        SELECT TOP 1 record_status_id FROM grac_practice.record_status_master
         WHERE status_code = N'Active' OR status_code = N'ACTIVE' OR status_name = N'Active'
         ORDER BY record_status_id);
    IF @active_rs IS NULL SET @active_rs = 1;

    DECLARE @created BIT = 0, @deps_added INT = 0, @sources_added INT = 0, @map_id BIGINT;

    BEGIN TRY
        BEGIN TRAN;

        SELECT @map_id = risk_practice_map_id
          FROM grac_practice.risk_practice_map
         WHERE risk_register_id     = @risk_register_id
           AND practice_instance_id = @practice_instance_id;

        IF @map_id IS NULL
        BEGIN
            -- Claim a practice-level row for the same practice, if any.
            SELECT TOP 1 @map_id = risk_practice_map_id
              FROM grac_practice.risk_practice_map
             WHERE risk_register_id     = @risk_register_id
               AND practice_id          = @practice_id
               AND practice_instance_id IS NULL
             ORDER BY risk_practice_map_id;

            IF @map_id IS NOT NULL
                UPDATE grac_practice.risk_practice_map
                   SET practice_instance_id   = @practice_instance_id,
                       practice_instance_name = @i_name,
                       practice_instance_code = @i_code,
                       updated_by             = @caller_display_name,
                       updated_dt             = SYSUTCDATETIME()
                 WHERE risk_practice_map_id = @map_id;
            ELSE
            BEGIN
                INSERT INTO grac_practice.risk_practice_map
                    (organization_id, risk_register_id, practice_id,
                     practice_name, practice_code, map_source_code,
                     practice_instance_id, practice_instance_name, practice_instance_code,
                     mapped_dt, mapped_by_employee_id, remarks,
                     record_status_id, entered_by, entered_dt)
                VALUES
                    (@org_id, @risk_register_id, @practice_id,
                     @p_name, @p_code,
                     -- Only one Primary per risk (ux_pm_risk_practice_map_primary).
                     CASE WHEN @map_source_code = N'Primary'
                           AND NOT EXISTS (SELECT 1 FROM grac_practice.risk_practice_map
                                            WHERE risk_register_id = @risk_register_id
                                              AND map_source_code  = N'Primary')
                          THEN N'Primary' ELSE N'Additional' END,
                     @practice_instance_id, @i_name, @i_code,
                     SYSUTCDATETIME(), @actor_employee_id, @remarks,
                     @active_rs, @caller_display_name, SYSUTCDATETIME());
                SET @map_id  = SCOPE_IDENTITY();
                SET @created = 1;
            END
        END

        -- Dependencies of THIS instance the risk does not have yet.
        INSERT INTO grac_practice.risk_dependency_map
            (organization_id, risk_register_id, dependency_type_id, dependency_type_name,
             dependency_object_id, dependency_object_name,
             first_mapped_dt, mapped_by_employee_id,
             record_status_id, entered_by, entered_dt)
        SELECT @org_id, @risk_register_id, d.DependencyTypeId, d.DependencyTypeName,
               d.DependencyObjectId, d.DependencyObjectName,
               SYSUTCDATETIME(), @actor_employee_id,
               @active_rs, @caller_display_name, SYSUTCDATETIME()
          FROM grac_practice.fn_risk_instance_dependencies(@org_id, @practice_instance_id) d
         WHERE NOT EXISTS (
                 SELECT 1 FROM grac_practice.risk_dependency_map m
                  WHERE m.risk_register_id     = @risk_register_id
                    AND m.dependency_type_id   = d.DependencyTypeId
                    AND m.dependency_object_id = d.DependencyObjectId);
        SET @deps_added = @@ROWCOUNT;

        -- Contribution rows, keyed on (practice, INSTANCE).
        INSERT INTO grac_practice.risk_dependency_map_source
            (risk_dependency_map_id, source_kind_code, practice_id,
             practice_instance_id, resolution_id,
             added_dt, added_by_employee_id, entered_by, entered_dt)
        SELECT m.risk_dependency_map_id, N'PracticeDependency', @practice_id,
               @practice_instance_id, d.ResolutionId,
               SYSUTCDATETIME(), @actor_employee_id,
               @caller_display_name, SYSUTCDATETIME()
          FROM grac_practice.fn_risk_instance_dependencies(@org_id, @practice_instance_id) d
          JOIN grac_practice.risk_dependency_map m
            ON m.risk_register_id     = @risk_register_id
           AND m.dependency_type_id   = d.DependencyTypeId
           AND m.dependency_object_id = d.DependencyObjectId
         WHERE NOT EXISTS (
                 SELECT 1 FROM grac_practice.risk_dependency_map_source s
                  WHERE s.risk_dependency_map_id = m.risk_dependency_map_id
                    AND s.source_kind_code       = N'PracticeDependency'
                    AND s.practice_id            = @practice_id
                    AND ISNULL(s.practice_instance_id, 0) = @practice_instance_id);
        SET @sources_added = @@ROWCOUNT;

        IF @created = 1 OR @deps_added > 0
            INSERT INTO grac_practice.risk_register_history
                (risk_register_id, action_code, from_status_code, to_status_code,
                 remark, actor_employee_id, actor_display_name, entered_by, entered_dt)
            VALUES
                (@risk_register_id, N'PracticeMapped', @status, @status,
                 CONCAT(N'Practice instance ', ISNULL(@i_name, CAST(@practice_instance_id AS NVARCHAR(20))),
                        N' (', ISNULL(@p_name, N''), N') mapped. ',
                        CAST(@deps_added AS NVARCHAR(10)), N' dependency(ies) newly in scope.'),
                 @actor_employee_id, @caller_display_name,
                 @caller_display_name, SYSUTCDATETIME());

        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH

    IF @suppress_result = 0
        SELECT @risk_register_id     AS RiskRegisterId,
               @map_id               AS RiskPracticeMapId,
               @practice_id          AS PracticeId,
               @p_name               AS PracticeName,
               @practice_instance_id AS PracticeInstanceId,
               @i_name               AS PracticeInstanceName,
               @created              AS Created,
               @deps_added           AS DependenciesAdded,
               @sources_added        AS ContributionsAdded;
END;
GO

-- =====================================================================
-- 3b. sp_risk_practice_instance_unmap  (by risk_practice_map_id)
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_practice_instance_unmap
    @risk_register_id     BIGINT,
    @risk_practice_map_id BIGINT,
    @actor_employee_id    BIGINT        = NULL,
    @caller_display_name  NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;

    IF @risk_register_id IS NULL OR @risk_practice_map_id IS NULL
        THROW 56766, 'sp_risk_practice_instance_unmap: risk_register_id and risk_practice_map_id are required.', 1;

    DECLARE @org_id BIGINT, @status NVARCHAR(30);
    SELECT @org_id = organization_id, @status = status_code
      FROM grac_practice.risk_register
     WHERE risk_register_id = @risk_register_id;
    IF @org_id IS NULL
        THROW 56767, 'sp_risk_practice_instance_unmap: risk not found.', 1;
    IF @status IN (N'Closed', N'Retired')
        THROW 56768, 'sp_risk_practice_instance_unmap: this risk is closed or retired -- reopen it before changing its practice mapping.', 1;

    DECLARE @practice_id BIGINT, @instance_id BIGINT, @map_source NVARCHAR(20), @label NVARCHAR(400);
    SELECT @practice_id = practice_id, @instance_id = practice_instance_id,
           @map_source  = map_source_code,
           @label = CONCAT(ISNULL(practice_instance_name, practice_name), N'')
      FROM grac_practice.risk_practice_map
     WHERE risk_practice_map_id = @risk_practice_map_id
       AND risk_register_id     = @risk_register_id;

    IF @practice_id IS NULL
    BEGIN
        SELECT @risk_register_id AS RiskRegisterId, @risk_practice_map_id AS RiskPracticeMapId,
               CAST(0 AS BIT) AS Removed, 0 AS DependenciesRemoved, 0 AS DependenciesKept;
        RETURN;
    END
    IF @map_source = N'Primary'
        THROW 56769, 'sp_risk_practice_instance_unmap: this is the risk''s primary practice instance. Change the risk''s linked practice instead of unmapping it here.', 1;

    DECLARE @removed INT = 0, @kept INT = 0;

    BEGIN TRY
        BEGIN TRAN;

        -- This row's contributions: its own instance; for a legacy
        -- practice-level row, the practice's contributions that no OTHER
        -- mapped instance row of the same practice still vouches for.
        DELETE s
          FROM grac_practice.risk_dependency_map_source s
          JOIN grac_practice.risk_dependency_map m
            ON m.risk_dependency_map_id = s.risk_dependency_map_id
         WHERE m.risk_register_id = @risk_register_id
           AND s.source_kind_code = N'PracticeDependency'
           AND s.practice_id      = @practice_id
           AND (   (@instance_id IS NOT NULL AND s.practice_instance_id = @instance_id)
                OR (@instance_id IS NULL
                    AND NOT EXISTS (SELECT 1 FROM grac_practice.risk_practice_map o
                                     WHERE o.risk_register_id     = @risk_register_id
                                       AND o.practice_id          = @practice_id
                                       AND o.risk_practice_map_id <> @risk_practice_map_id
                                       AND o.practice_instance_id = s.practice_instance_id)));

        DELETE m
          FROM grac_practice.risk_dependency_map m
         WHERE m.risk_register_id = @risk_register_id
           AND NOT EXISTS (SELECT 1 FROM grac_practice.risk_dependency_map_source s
                            WHERE s.risk_dependency_map_id = m.risk_dependency_map_id);
        SET @removed = @@ROWCOUNT;

        DELETE FROM grac_practice.risk_practice_map
         WHERE risk_practice_map_id = @risk_practice_map_id;

        SELECT @kept = COUNT(*) FROM grac_practice.risk_dependency_map
         WHERE risk_register_id = @risk_register_id;

        INSERT INTO grac_practice.risk_register_history
            (risk_register_id, action_code, from_status_code, to_status_code,
             remark, actor_employee_id, actor_display_name, entered_by, entered_dt)
        VALUES
            (@risk_register_id, N'PracticeUnmapped', @status, @status,
             CONCAT(N'Practice instance ', @label, N' unmapped. ',
                    CAST(@removed AS NVARCHAR(10)), N' dependency(ies) dropped, ',
                    CAST(@kept AS NVARCHAR(10)), N' retained.'),
             @actor_employee_id, @caller_display_name,
             @caller_display_name, SYSUTCDATETIME());

        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH

    SELECT @risk_register_id     AS RiskRegisterId,
           @risk_practice_map_id AS RiskPracticeMapId,
           CAST(1 AS BIT)        AS Removed,
           @removed              AS DependenciesRemoved,
           @kept                 AS DependenciesKept;
END;
GO

-- =====================================================================
-- 4. sp_risk_practice_map_expand_instances
--    Every practice-level row (instance NULL) on the risk becomes the
--    practice's ACTIVE instances in the organisation: the row itself is
--    claimed by one instance (the source gap's instance first when the
--    row is Primary) and one Additional row is added per further
--    instance. A practice with no active instance keeps its
--    practice-level row -- nothing to convert it to.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_practice_map_expand_instances
    @risk_register_id    BIGINT,
    @caller_display_name NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    IF @risk_register_id IS NULL RETURN;

    DECLARE @org_id BIGINT, @src_type NVARCHAR(40), @src_id BIGINT, @status NVARCHAR(30);
    SELECT @org_id = organization_id, @src_type = source_type_code,
           @src_id = source_record_id, @status = status_code
      FROM grac_practice.risk_register
     WHERE risk_register_id = @risk_register_id;
    IF @org_id IS NULL OR @status IN (N'Closed', N'Retired') RETURN;

    DECLARE @src_instance BIGINT = NULL;
    IF @src_type = N'Gap' AND @src_id IS NOT NULL
        SELECT @src_instance = g.source_reference_id
          FROM grac_practice.custom_gap g
         WHERE g.custom_gap_id = @src_id AND g.source_reference_type = N'PracticeInstance';

    DECLARE @rows TABLE(map_id BIGINT, practice_id BIGINT, is_primary BIT);
    INSERT @rows
    SELECT risk_practice_map_id, practice_id,
           CASE WHEN map_source_code = N'Primary' THEN 1 ELSE 0 END
      FROM grac_practice.risk_practice_map
     WHERE risk_register_id = @risk_register_id
       AND practice_instance_id IS NULL;

    DECLARE @map_id BIGINT, @practice_id BIGINT, @is_primary BIT, @inst BIGINT;
    DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT map_id, practice_id, is_primary FROM @rows;
    OPEN c;
    FETCH NEXT FROM c INTO @map_id, @practice_id, @is_primary;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        -- Claim instance first (the claim path of instance_map picks up
        -- THIS row because it is the practice-level row for the practice).
        SELECT TOP 1 @inst = pi.practice_instance_id
          FROM grac_practice.practice_instance pi
         WHERE pi.practice_id = @practice_id AND pi.organization_id = @org_id
           AND pi.status = N'Active'
           AND NOT EXISTS (SELECT 1 FROM grac_practice.risk_practice_map x
                            WHERE x.risk_register_id = @risk_register_id
                              AND x.practice_instance_id = pi.practice_instance_id)
         ORDER BY CASE WHEN @is_primary = 1 AND pi.practice_instance_id = @src_instance THEN 0 ELSE 1 END,
                  pi.practice_instance_id;

        IF @inst IS NOT NULL
        BEGIN
            EXEC grac_practice.sp_risk_practice_instance_map
                 @risk_register_id = @risk_register_id, @practice_instance_id = @inst,
                 @caller_display_name = @caller_display_name, @suppress_result = 1;

            -- Every other active instance of the practice: Additional rows.
            DECLARE @more TABLE(inst BIGINT);
            DELETE FROM @more;
            INSERT @more
            SELECT pi.practice_instance_id
              FROM grac_practice.practice_instance pi
             WHERE pi.practice_id = @practice_id AND pi.organization_id = @org_id
               AND pi.status = N'Active'
               AND NOT EXISTS (SELECT 1 FROM grac_practice.risk_practice_map x
                                WHERE x.risk_register_id = @risk_register_id
                                  AND x.practice_instance_id = pi.practice_instance_id);
            DECLARE @m BIGINT;
            DECLARE c2 CURSOR LOCAL FAST_FORWARD FOR SELECT inst FROM @more;
            OPEN c2;
            FETCH NEXT FROM c2 INTO @m;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                EXEC grac_practice.sp_risk_practice_instance_map
                     @risk_register_id = @risk_register_id, @practice_instance_id = @m,
                     @caller_display_name = @caller_display_name, @suppress_result = 1;
                FETCH NEXT FROM c2 INTO @m;
            END
            CLOSE c2; DEALLOCATE c2;
        END
        SET @inst = NULL;
        FETCH NEXT FROM c INTO @map_id, @practice_id, @is_primary;
    END
    CLOSE c; DEALLOCATE c;
END;
GO

-- =====================================================================
-- 5. sp_risk_mapping_sync_primary (354 body; one-row Primary promotion)
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

    DECLARE @org_id BIGINT, @practice_id BIGINT,
            @src_type NVARCHAR(40), @src_id BIGINT;
    SELECT @org_id      = organization_id,
           @practice_id = linked_practice_id,
           @src_type    = source_type_code,
           @src_id      = source_record_id
      FROM grac_practice.risk_register
     WHERE risk_register_id = @risk_register_id;

    IF @org_id IS NULL
        THROW 56661, 'sp_risk_mapping_sync_primary: risk not found.', 1;

    -- 354: the column is still NULL -- try to derive it, same join as
    -- the create-time step, and persist it so this is the last time
    -- this particular risk needs to take this branch.
    IF @practice_id IS NULL
       AND @src_type = N'Gap'
       AND @src_id IS NOT NULL
    BEGIN
        SELECT @practice_id = pi.practice_id
          FROM grac_practice.custom_gap g
          JOIN grac_practice.practice_instance pi
               ON pi.practice_instance_id = g.source_reference_id
         WHERE g.custom_gap_id        = @src_id
           AND g.source_reference_type = N'PracticeInstance'
           AND pi.organization_id      = @org_id;

        IF @practice_id IS NOT NULL
            UPDATE grac_practice.risk_register
               SET linked_practice_id = @practice_id,
                   updated_by         = @caller_display_name,
                   updated_dt         = SYSUTCDATETIME()
             WHERE risk_register_id = @risk_register_id
               AND linked_practice_id IS NULL;
    END

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
        -- 387: since risks map practice INSTANCES, one practice can have
        -- several rows on a risk. Promote exactly ONE of them (the
        -- source gap's instance when known, else the oldest row) -- a
        -- blanket UPDATE would break ux_pm_risk_practice_map_primary.
        DECLARE @src_instance BIGINT = NULL;
        IF @src_type = N'Gap' AND @src_id IS NOT NULL
            SELECT @src_instance = g.source_reference_id
              FROM grac_practice.custom_gap g
             WHERE g.custom_gap_id = @src_id
               AND g.source_reference_type = N'PracticeInstance';

        UPDATE grac_practice.risk_practice_map
           SET map_source_code = N'Primary',
               updated_by      = @caller_display_name,
               updated_dt      = SYSUTCDATETIME()
         WHERE risk_practice_map_id = (
               SELECT TOP 1 x.risk_practice_map_id
                 FROM grac_practice.risk_practice_map x
                WHERE x.risk_register_id = @risk_register_id
                  AND x.practice_id      = @practice_id
                ORDER BY CASE WHEN x.practice_instance_id = @src_instance THEN 0 ELSE 1 END,
                         x.risk_practice_map_id);

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
-- 6. sp_risk_mapping_get (267 body + instance columns)
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
           -- 387: counted per INSTANCE when the row is instance-level, so
           -- two instances of one practice report their own numbers.
           (SELECT COUNT(*)
              FROM grac_practice.risk_dependency_map_source s
              JOIN grac_practice.risk_dependency_map m
                ON m.risk_dependency_map_id = s.risk_dependency_map_id
             WHERE m.risk_register_id = @risk_register_id
               AND s.practice_id      = pm.practice_id
               AND (pm.practice_instance_id IS NULL
                    OR s.practice_instance_id = pm.practice_instance_id)) AS DependencyCount,
           -- 387: the mapped practice INSTANCE (NULL on a row not yet
           -- expanded -- see sp_risk_practice_map_expand_instances).
           pm.practice_instance_id       AS PracticeInstanceId,
           COALESCE(pi.instance_name, pm.practice_instance_name) AS PracticeInstanceName,
           COALESCE(pi.instance_code, pm.practice_instance_code) AS PracticeInstanceCode
      FROM grac_practice.risk_practice_map pm
      LEFT JOIN grac_practice.practice p ON p.practice_id = pm.practice_id
      LEFT JOIN grac_practice.organization_employee e ON e.employee_id = pm.mapped_by_employee_id
      LEFT JOIN grac_practice.practice_instance pi ON pi.practice_instance_id = pm.practice_instance_id
     WHERE pm.risk_register_id = @risk_register_id
     ORDER BY CASE WHEN pm.map_source_code = N'Primary' THEN 0 ELSE 1 END,
              COALESCE(p.practice_name, pm.practice_name),
              COALESCE(pi.instance_name, pm.practice_instance_name);

    -- ---- 2. The categories Operationalize OFFERS ------------------
    SELECT dt.dependency_type_id   AS DependencyTypeId,
           dt.dependency_type_code AS DependencyTypeCode,
           dt.dependency_type_name AS DependencyTypeName,
           dt.display_order        AS DisplayOrder,
           CAST(CASE WHEN sc.dependency_type_id IS NULL THEN 0 ELSE 1 END AS BIT) AS IsSelectable,
           (SELECT COUNT(*) FROM grac_practice.risk_dependency_map m
             WHERE m.risk_register_id   = @risk_register_id
               AND m.dependency_type_id = dt.dependency_type_id) AS MappedCount
      FROM grac_practice.dependency_type_master dt
      LEFT JOIN grac_practice.dependency_type_source_config sc
             ON sc.dependency_type_id = dt.dependency_type_id
            AND sc.status = N'Active'
     WHERE dt.is_active = 1
       -- NEW in 267. This one predicate is the whole difference between
       -- "every category that exists" and "the five this product offers".
       AND dt.is_dependency_mappable = 1
     ORDER BY dt.display_order, dt.dependency_type_name;

    -- ---- 3. Mapped dependencies, with provenance ------------------
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

           -- 387: the name comes from a TOP 1 lookup, not a join -- a
           -- practice can now sit on the risk once per instance, and a
           -- join would repeat its name once per row. The name is resolved
           -- in the derived table (OUTER APPLY) so STRING_AGG aggregates a
           -- plain column: an aggregate over an expression that contains a
           -- subquery is Msg 130.
           (SELECT STRING_AGG(CONVERT(NVARCHAR(MAX), s2.practice_name), N', ')
              FROM (SELECT d.practice_id,
                           COALESCE(pp.practice_name, fb.practice_name) AS practice_name
                      FROM (SELECT DISTINCT sx.practice_id
                              FROM grac_practice.risk_dependency_map_source sx
                             WHERE sx.risk_dependency_map_id = m.risk_dependency_map_id
                               AND sx.source_kind_code       = N'PracticeDependency') d
                      LEFT JOIN grac_practice.practice pp ON pp.practice_id = d.practice_id
                      OUTER APPLY (SELECT TOP 1 pm2.practice_name
                                     FROM grac_practice.risk_practice_map pm2
                                    WHERE pm2.risk_register_id = @risk_register_id
                                      AND pm2.practice_id      = d.practice_id
                                    ORDER BY pm2.risk_practice_map_id) fb) s2) AS SourcePractices
      FROM grac_practice.risk_dependency_map m
      LEFT JOIN grac_practice.dependency_type_master dt
             ON dt.dependency_type_id = m.dependency_type_id
     WHERE m.risk_register_id = @risk_register_id
     ORDER BY dt.display_order, m.dependency_object_name;
END;
GO

-- =====================================================================
-- 7. sp_practice_picker_instances -- the picker's Instance level
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_practice_picker_instances
    @organization_id   BIGINT,
    @practice_id       BIGINT,
    @risk_register_id  BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL OR @practice_id IS NULL
        THROW 57010, 'sp_practice_picker_instances: organization_id and practice_id are required.', 1;

    SELECT pi.practice_instance_id  AS PracticeInstanceId,
           pi.instance_code         AS InstanceCode,
           pi.instance_name         AS InstanceName,
           pi.department            AS Department,
           pi.primary_owner         AS PrimaryOwner,
           pi.practice_id           AS PracticeId,
           CAST(CASE WHEN @risk_register_id IS NOT NULL
                      AND EXISTS (SELECT 1 FROM grac_practice.risk_practice_map pm
                                   WHERE pm.risk_register_id     = @risk_register_id
                                     AND pm.practice_instance_id = pi.practice_instance_id)
                     THEN 1 ELSE 0 END AS BIT) AS AlreadyMappedToRisk,
           (SELECT TOP 1 pm2.map_source_code
              FROM grac_practice.risk_practice_map pm2
             WHERE pm2.risk_register_id     = @risk_register_id
               AND pm2.practice_instance_id = pi.practice_instance_id) AS MapSourceCode
      FROM grac_practice.practice_instance pi
     WHERE pi.organization_id = @organization_id
       AND pi.practice_id     = @practice_id
       AND pi.status          = N'Active'
     ORDER BY pi.instance_code, pi.instance_name;
END;
GO

-- =====================================================================
-- 8. "Map open task": risk_treatment_task_link + procs
-- =====================================================================
IF OBJECT_ID('grac_practice.risk_treatment_task_link','U') IS NULL
CREATE TABLE grac_practice.risk_treatment_task_link(
    risk_treatment_task_link_id BIGINT IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_risk_treatment_task_link PRIMARY KEY,
    organization_id      BIGINT NOT NULL
        CONSTRAINT fk_pm_risk_tt_link_org REFERENCES grac_practice.organization(organization_id),
    risk_register_id     BIGINT NOT NULL
        CONSTRAINT fk_pm_risk_tt_link_risk REFERENCES grac_practice.risk_register(risk_register_id),
    task_id              BIGINT NOT NULL
        CONSTRAINT fk_pm_risk_tt_link_task REFERENCES grac_practice.practice_task(task_id),
    linked_by_employee_id BIGINT NULL,
    remarks              NVARCHAR(1000) NULL,
    entered_by NVARCHAR(100) NOT NULL CONSTRAINT df_pm_risk_tt_link_by DEFAULT N'system',
    entered_dt DATETIME2 NOT NULL CONSTRAINT df_pm_risk_tt_link_dt DEFAULT SYSUTCDATETIME(),
    CONSTRAINT uq_pm_risk_treatment_task_link UNIQUE(risk_register_id, task_id)
);
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_risk_treatment_task_link
    @risk_register_id    BIGINT,
    @task_id             BIGINT,
    @remarks             NVARCHAR(1000) = NULL,
    @actor_employee_id   BIGINT         = NULL,
    @caller_display_name NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    IF @risk_register_id IS NULL OR @task_id IS NULL
        THROW 56770, 'sp_risk_treatment_task_link: risk_register_id and task_id are required.', 1;

    DECLARE @org_id BIGINT, @status NVARCHAR(30);
    SELECT @org_id = organization_id, @status = status_code
      FROM grac_practice.risk_register WHERE risk_register_id = @risk_register_id;
    IF @org_id IS NULL
        THROW 56771, 'sp_risk_treatment_task_link: risk not found.', 1;
    IF @status IN (N'Closed', N'Retired')
        THROW 56772, 'sp_risk_treatment_task_link: this risk is closed or retired.', 1;

    DECLARE @t_org BIGINT, @closed DATETIME2, @terminal BIT, @number NVARCHAR(60), @parent BIGINT;
    SELECT @t_org = v.organization_id, @closed = v.closed_at,
           @terminal = v.current_status_is_terminal, @number = v.task_number,
           @parent = v.parent_task_id
      FROM grac_practice.vw_pm_practice_task v WHERE v.task_id = @task_id;
    IF @t_org IS NULL
        THROW 56773, 'sp_risk_treatment_task_link: task not found.', 1;
    IF @t_org <> @org_id
        THROW 56774, 'sp_risk_treatment_task_link: that task belongs to a different organisation.', 1;
    IF @closed IS NOT NULL OR ISNULL(@terminal, 0) = 1
        THROW 56775, 'sp_risk_treatment_task_link: only an OPEN task can be mapped.', 1;
    IF @parent IS NOT NULL
        THROW 56776, 'sp_risk_treatment_task_link: map the parent task -- its sub tasks come with it.', 1;

    IF NOT EXISTS (SELECT 1 FROM grac_practice.risk_treatment_task_link
                    WHERE risk_register_id = @risk_register_id AND task_id = @task_id)
    BEGIN
        INSERT grac_practice.risk_treatment_task_link
            (organization_id, risk_register_id, task_id, linked_by_employee_id, remarks, entered_by)
        VALUES (@org_id, @risk_register_id, @task_id, @actor_employee_id, @remarks, @caller_display_name);

        INSERT INTO grac_practice.risk_register_history
            (risk_register_id, action_code, from_status_code, to_status_code,
             remark, actor_employee_id, actor_display_name, entered_by, entered_dt)
        VALUES (@risk_register_id, N'TreatmentTaskMapped', @status, @status,
                CONCAT(N'Open task ', ISNULL(@number, CAST(@task_id AS NVARCHAR(20))),
                       N' mapped as treatment work.'),
                @actor_employee_id, @caller_display_name, @caller_display_name, SYSUTCDATETIME());
    END

    SELECT @risk_register_id AS RiskRegisterId, @task_id AS TaskId, CAST(1 AS BIT) AS Linked;
END;
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_risk_treatment_task_unlink
    @risk_register_id    BIGINT,
    @task_id             BIGINT,
    @actor_employee_id   BIGINT        = NULL,
    @caller_display_name NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @status NVARCHAR(30) = (SELECT status_code FROM grac_practice.risk_register
                                     WHERE risk_register_id = @risk_register_id);
    DELETE FROM grac_practice.risk_treatment_task_link
     WHERE risk_register_id = @risk_register_id AND task_id = @task_id;
    DECLARE @n INT = @@ROWCOUNT;
    IF @n > 0
        INSERT INTO grac_practice.risk_register_history
            (risk_register_id, action_code, from_status_code, to_status_code,
             remark, actor_employee_id, actor_display_name, entered_by, entered_dt)
        VALUES (@risk_register_id, N'TreatmentTaskUnmapped', @status, @status,
                CONCAT(N'Task #', CAST(@task_id AS NVARCHAR(20)), N' unmapped from treatment work.'),
                @actor_employee_id, @caller_display_name, @caller_display_name, SYSUTCDATETIME());
    SELECT @risk_register_id AS RiskRegisterId, @task_id AS TaskId,
           CAST(CASE WHEN @n > 0 THEN 1 ELSE 0 END AS BIT) AS Removed;
END;
GO

-- Open top-level tasks of the risk's organisation that are not already
-- part of this risk's treatment work.
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_open_task_list
    @risk_register_id BIGINT,
    @search           NVARCHAR(200) = NULL,
    @top              INT           = 200
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @org_id BIGINT, @candidate_id BIGINT;
    SELECT @org_id = organization_id, @candidate_id = risk_candidate_id
      FROM grac_practice.risk_register WHERE risk_register_id = @risk_register_id;
    IF @org_id IS NULL
        THROW 56777, 'sp_risk_open_task_list: risk not found.', 1;
    IF @top IS NULL OR @top <= 0 SET @top = 200;

    SELECT TOP (@top)
           v.task_id                   AS TaskId,
           v.task_number               AS TaskNumber,
           v.subject_title             AS Title,
           v.current_status_name       AS StatusName,
           v.assigned_to_employee_name AS OwnerName,
           v.priority                  AS Priority,
           v.sla_due_at                AS DueAt,
           v.source_type_code          AS SourceTypeCode,
           v.source_reference          AS SourceReference
      FROM grac_practice.vw_pm_practice_task v
     WHERE v.organization_id = @org_id
       AND v.parent_task_id IS NULL
       AND v.closed_at IS NULL
       AND ISNULL(v.current_status_is_terminal, 0) = 0
       AND NOT (v.source_type_code = N'RiskRegister' AND v.source_record_id = @risk_register_id)
       AND NOT (@candidate_id IS NOT NULL AND v.source_type_code = N'Risk' AND v.source_record_id = @candidate_id)
       AND NOT EXISTS (SELECT 1 FROM grac_practice.risk_treatment_task_link l
                        WHERE l.risk_register_id = @risk_register_id AND l.task_id = v.task_id)
       AND (@search IS NULL OR LEN(LTRIM(RTRIM(@search))) = 0
            OR v.task_number   LIKE N'%' + @search + N'%'
            OR v.subject_title LIKE N'%' + @search + N'%')
     ORDER BY v.entered_dt DESC;
END;
GO

-- =====================================================================
-- 9. sp_risk_treatment_state (263 body + gap tasks + linked tasks)
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_treatment_state
    @risk_register_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    IF @risk_register_id IS NULL
        THROW 56570, 'sp_risk_treatment_state: risk_register_id is required.', 1;

    DECLARE @org_id BIGINT, @candidate_id BIGINT, @option_code NVARCHAR(30),
            @status NVARCHAR(30), @residual_pending BIT, @analysis_pending BIT;

    SELECT @org_id           = organization_id,
           @candidate_id     = risk_candidate_id,
           @option_code      = treatment_option_code,
           @status           = status_code,
           @residual_pending = residual_pending,
           @analysis_pending = analysis_pending
      FROM grac_practice.risk_register
     WHERE risk_register_id = @risk_register_id;

    IF @org_id IS NULL
        THROW 56571, 'sp_risk_treatment_state: risk not found.', 1;

    -- 387: the top-level tasks that make up this risk's treatment work,
    -- each with where it came from. A task reachable two ways is listed
    -- once, under the first source in this order.
    CREATE TABLE #roots(TaskId BIGINT PRIMARY KEY, LinkSourceCode NVARCHAR(20));

    INSERT #roots(TaskId, LinkSourceCode)
    SELECT v.task_id, N'Treatment'
      FROM grac_practice.vw_pm_practice_task v
     WHERE v.organization_id = @org_id
       AND v.parent_task_id IS NULL
       AND ((v.source_type_code = N'RiskRegister' AND v.source_record_id = @risk_register_id)
         OR (@candidate_id IS NOT NULL
             AND v.source_type_code = N'Risk' AND v.source_record_id = @candidate_id));

    -- Tasks raised from gaps on a mapped practice INSTANCE.
    INSERT #roots(TaskId, LinkSourceCode)
    SELECT DISTINCT v.task_id, N'Gap'
      FROM grac_practice.risk_practice_map pm
      JOIN grac_practice.custom_gap g
        ON g.source_reference_type = N'PracticeInstance'
       AND g.source_reference_id   = pm.practice_instance_id
      JOIN grac_practice.vw_pm_practice_task v
        ON v.source_type_code = N'Gap'
       AND v.source_record_id = g.custom_gap_id
       AND v.organization_id  = @org_id
       AND v.parent_task_id IS NULL
     WHERE pm.risk_register_id = @risk_register_id
       AND pm.practice_instance_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM #roots r WHERE r.TaskId = v.task_id);

    -- Open tasks mapped with "Map open task".
    IF OBJECT_ID('grac_practice.risk_treatment_task_link','U') IS NOT NULL
        INSERT #roots(TaskId, LinkSourceCode)
        SELECT l.task_id, N'Linked'
          FROM grac_practice.risk_treatment_task_link l
         WHERE l.risk_register_id = @risk_register_id
           AND NOT EXISTS (SELECT 1 FROM #roots r WHERE r.TaskId = l.task_id);

    CREATE TABLE #tt(
        TaskId BIGINT, TaskNumber NVARCHAR(60), Title NVARCHAR(250),
        StatusCode NVARCHAR(30), StatusName NVARCHAR(120), IsTerminal BIT,
        OwnerEmployeeId BIGINT, OwnerName NVARCHAR(240), Priority NVARCHAR(30),
        DueAt DATETIME2, ClosedAt DATETIME2, IsChild BIT, ParentTaskId BIGINT,
        ChildCount INT, MandatoryChildOpenCount INT, RaisedDt DATETIME2,
        LinkSourceCode NVARCHAR(20)
    );

    -- Each root task plus its sub tasks (children inherit the root's
    -- LinkSourceCode). Same columns and order as 263.
    INSERT INTO #tt
    SELECT v.task_id, v.task_number, v.subject_title,
           v.current_status_code, v.current_status_name, v.current_status_is_terminal,
           v.assigned_to_employee_id, v.assigned_to_employee_name, v.priority,
           v.sla_due_at, v.closed_at,
           CASE WHEN v.parent_task_id IS NOT NULL THEN 1 ELSE 0 END,
           v.parent_task_id, v.child_count, v.mandatory_child_open_count, v.entered_dt,
           r.LinkSourceCode
      FROM grac_practice.vw_pm_practice_task v
      JOIN #roots r ON r.TaskId = COALESCE(v.parent_task_id, v.task_id)
     WHERE v.organization_id = @org_id;

    DECLARE @total INT, @open INT, @closed INT, @open_children INT;

    SELECT @total  = COUNT(*),
           @open   = SUM(CASE WHEN ClosedAt IS NULL AND IsTerminal = 0 THEN 1 ELSE 0 END),
           @closed = SUM(CASE WHEN ClosedAt IS NOT NULL OR IsTerminal = 1 THEN 1 ELSE 0 END)
      FROM #tt WHERE IsChild = 0;

    SELECT @open_children = COUNT(*)
      FROM #tt WHERE IsChild = 1 AND ClosedAt IS NULL AND IsTerminal = 0;

    SET @total  = ISNULL(@total, 0);
    SET @open   = ISNULL(@open, 0);
    SET @closed = ISNULL(@closed, 0);

    DECLARE @residual_available BIT =
        CASE WHEN ISNULL(@analysis_pending, 1) = 1 THEN 0
             WHEN @status IN (N'Closed', N'Retired')  THEN 0
             WHEN @option_code IS NULL                THEN 0
             WHEN @option_code = N'Tolerate'          THEN 0
             WHEN @total = 0                          THEN 0
             WHEN @open > 0                           THEN 0
             ELSE 1 END;

    DECLARE @reason NVARCHAR(400) =
        CASE WHEN ISNULL(@analysis_pending, 1) = 1
                  THEN N'Complete the risk analysis first.'
             WHEN @status IN (N'Closed', N'Retired')
                  THEN N'This risk is closed or retired.'
             WHEN @option_code IS NULL
                  THEN N'Choose a treatment option first.'
             WHEN @option_code = N'Tolerate'
                  THEN N'Tolerate / Accept does not require residual analysis -- go to Risk Acceptance.'
             WHEN @total = 0
                  THEN N'No treatment task has been raised yet.'
             WHEN @open > 0
                  THEN CONCAT(CAST(@open AS NVARCHAR(10)),
                              N' treatment task(s) still open.',
                              CASE WHEN @open_children > 0
                                   THEN CONCAT(N' ', CAST(@open_children AS NVARCHAR(10)),
                                               N' sub task(s) open.')
                                   ELSE N'' END)
             ELSE N'All treatment tasks are closed -- residual risk analysis is available.'
        END;

    SELECT @risk_register_id   AS RiskRegisterId,
           @option_code        AS TreatmentOptionCode,
           @status             AS StatusCode,
           @total              AS TreatmentTaskCount,
           @open               AS OpenTreatmentTaskCount,
           @closed             AS ClosedTreatmentTaskCount,
           @open_children      AS OpenSubTaskCount,
           @residual_available AS ResidualAvailable,
           ISNULL(@residual_pending, 1) AS ResidualPending,
           @reason             AS Reason;

    SELECT * FROM #tt ORDER BY IsChild, ParentTaskId, TaskId;
    DROP TABLE #tt;
    DROP TABLE #roots;
END;
GO

-- =====================================================================
-- Backfill: every existing practice-level mapping -> instance rows
-- (confirmed with sir). Idempotent: rows already instance-level are
-- skipped by the expand procedure itself.
-- =====================================================================
DECLARE @r BIGINT, @n INT = 0;
DECLARE bf CURSOR LOCAL FAST_FORWARD FOR
    SELECT DISTINCT pm.risk_register_id
      FROM grac_practice.risk_practice_map pm
     WHERE pm.practice_instance_id IS NULL;
OPEN bf;
FETCH NEXT FROM bf INTO @r;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        EXEC grac_practice.sp_risk_practice_map_expand_instances
             @risk_register_id = @r, @caller_display_name = N'seed-387';
        SET @n = @n + 1;
    END TRY
    BEGIN CATCH
        PRINT CONCAT('387: backfill skipped risk ', @r, ' -- ', ERROR_MESSAGE());
    END CATCH
    FETCH NEXT FROM bf INTO @r;
END
CLOSE bf; DEALLOCATE bf;
PRINT '387: backfill processed risks = ' + CAST(@n AS NVARCHAR(20));
GO

-- =====================================================================
-- Verification
-- =====================================================================
SELECT '387-a risk_practice_map has practice_instance_id' AS Check_,
       CASE WHEN COL_LENGTH('grac_practice.risk_practice_map','practice_instance_id') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '387-b new procedures exist',
       CASE WHEN OBJECT_ID('grac_practice.sp_risk_practice_instance_map','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_risk_practice_instance_unmap','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_risk_practice_map_expand_instances','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_practice_picker_instances','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_risk_treatment_task_link','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_risk_treatment_task_unlink','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_risk_open_task_list','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '387-c sp_risk_treatment_state returns LinkSourceCode',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_risk_treatment_state')) LIKE '%LinkSourceCode%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '387-d sp_risk_mapping_get returns PracticeInstanceId',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_risk_mapping_get')) LIKE '%PracticeInstanceId%'
            THEN 'PASS' ELSE 'FAIL' END;

PRINT '--- Mappings still practice-level (practice has no active instance) ---';
SELECT pm.risk_register_id, pm.practice_id, pm.practice_name, pm.map_source_code
  FROM grac_practice.risk_practice_map pm
 WHERE pm.practice_instance_id IS NULL;

PRINT '387 complete.';
GO
SET NOEXEC OFF;
GO
