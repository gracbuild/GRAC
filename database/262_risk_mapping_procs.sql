-- =====================================================================
-- 262 Risk Centre — Practice and Asset mapping procedures
--
-- WHAT THIS FILE OWNS
-- -------------------
-- Every write to risk_practice_map, risk_asset_map and
-- risk_asset_map_source goes through one of these procedures. Nothing
-- else in GRAC writes those tables, which is what makes the invariants
-- in 261's header enforceable rather than aspirational.
--
-- THE ONE IDEA THIS FILE IS BUILT ON
-- ----------------------------------
-- Mapping is a SET operation, not a row operation.
--
-- "Map practice P to risk R" means: R gains P, and R gains every asset
-- P depends on that it does not already have, and R records that P is
-- the reason for each of them. Written as a loop over assets, that is
-- three round trips per asset and a dozen edge cases. Written as
-- MERGE-shaped set logic against one inline table-valued function, it is
-- three statements and the edge cases are constraints.
--
-- So the asset resolution lives in ONE place --
-- fn_risk_practice_assets -- and every procedure here composes it.
-- If the definition of "the assets a practice depends on" ever changes,
-- there is exactly one function to change and no procedure to re-audit.
--
-- WHY AN INLINE TVF AND NOT A PROCEDURE
-- -------------------------------------
-- An inline TVF is expanded into the calling query by the optimiser --
-- it behaves like a view with parameters, not like a call. That lets the
-- insert, the delete and the read paths all use the same definition
-- while still producing single set-based plans. A procedure would force
-- a #temp table at every call site, and a multi-statement TVF would
-- force a table variable with no statistics; both turn a three-statement
-- procedure into something that needs its own performance note.
--
-- THE PRACTICE -> ASSET CHAIN, AND THE ONE SUBTLETY IN IT
-- -------------------------------------------------------
--   practice
--     -> practice_instance          (the practice, as operated)
--       -> practice_dependency_resolution  (what the instance depends on)
--         -> organization_dependency_asset (the asset itself)
--
-- The subtlety is the middle hop. risk_register.linked_practice_id is a
-- catalogue practice_id, but dependencies are resolved per INSTANCE. A
-- practice with three instances in three regions can therefore depend on
-- three different sets of assets, and the risk touches all of them --
-- so the function unions across instances and DISTINCTs the result.
-- The instance that produced each asset is carried out of the function
-- so the contribution row can record it (261, decision 2).
--
-- Only ACTIVE instances and ACTIVE resolutions count. A retired instance
-- is not something the organisation still depends on, and inheriting its
-- assets would put decommissioned kit on live risks.
--
-- CONTENTS
--   1. fn_risk_practice_assets          inline TVF, the one definition
--   2. sp_risk_mapping_sync_primary     linked_practice_id -> Primary row
--   3. sp_risk_practice_map             map a practice + inherit assets
--   4. sp_risk_practice_unmap           unmap, without stealing assets
--   5. sp_risk_asset_map_direct         map an asset with no practice
--   6. sp_risk_asset_unmap              remove a direct mapping
--   7. sp_risk_mapping_get              both lists, for the screen
--   8. sp_risk_mapping_options          practice + asset picklists
--
-- ADDITIVE ONLY. No existing object is modified.
-- ERROR CODE RANGE: 56520-56559
-- Rollback: database/262_risk_mapping_procs_rollback.sql
-- Depends:  001, 002, 015, 205, 261
-- Docs:     docs/risk-centre.md
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

DECLARE @ok BIT = 1;

IF OBJECT_ID('grac_practice.risk_practice_map','U') IS NULL
BEGIN PRINT 'ABORT (262): risk_practice_map missing -- run 261 first.'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.risk_asset_map','U') IS NULL
BEGIN PRINT 'ABORT (262): risk_asset_map missing -- run 261 first.'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.risk_asset_map_source','U') IS NULL
BEGIN PRINT 'ABORT (262): risk_asset_map_source missing -- run 261 first.'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.practice_dependency_resolution','U') IS NULL
BEGIN PRINT 'ABORT (262): practice_dependency_resolution missing -- run 002 first.'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.dependency_type_master','U') IS NULL
BEGIN PRINT 'ABORT (262): dependency_type_master missing -- run 015 first.'; SET @ok = 0; END

IF @ok = 0
BEGIN
    RAISERROR('262_risk_mapping_procs: prerequisites missing -- see PRINT messages above.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. fn_risk_practice_assets
--
-- The assets a practice depends on, in this organisation. See the header
-- for why this is an inline TVF and why it unions across instances.
--
-- The dependency type is matched on dependency_type_code = 'Asset'
-- (seeded by 015) rather than on a hard-coded id, because ids are
-- IDENTITY values and differ between environments.
--
-- DISTINCT with an aggregate on the instance: an asset reachable from
-- two instances of the SAME practice is still one asset. MIN picks a
-- representative instance for the contribution row -- deterministic, and
-- honest, because the contribution is "this practice", not "this
-- instance"; the instance is a breadcrumb, not a key.
-- =====================================================================
CREATE OR ALTER FUNCTION grac_practice.fn_risk_practice_assets
(
    @organization_id BIGINT,
    @practice_id     BIGINT
)
RETURNS TABLE
AS
RETURN
(
    SELECT r.resolved_dependency_id                     AS AssetId,
           MIN(a.asset_name)                            AS AssetName,
           MIN(pi.practice_instance_id)                 AS PracticeInstanceId,
           MIN(r.resolution_id)                         AS ResolutionId
      FROM grac_practice.practice_instance pi
      JOIN grac_practice.practice_dependency_resolution r
        ON r.practice_instance_id = pi.practice_instance_id
       AND r.is_active = 1
      JOIN grac_practice.dependency_type_master dt
        ON dt.dependency_type_id = r.dependency_type_id
       AND dt.dependency_type_code = N'Asset'
      JOIN grac_practice.organization_dependency_asset a
        ON a.asset_id = r.resolved_dependency_id
       AND a.organization_id = @organization_id
     WHERE pi.practice_id     = @practice_id
       AND pi.organization_id = @organization_id
       AND pi.status = N'Active'
       AND r.organization_id  = @organization_id
     GROUP BY r.resolved_dependency_id
);
GO

-- =====================================================================
-- 2. sp_risk_mapping_sync_primary
--
-- Mirrors risk_register.linked_practice_id into risk_practice_map as the
-- single 'Primary' row, and inherits its assets.
--
-- WHY THIS EXISTS AS A SEPARATE, IDEMPOTENT PROCEDURE
-- ---------------------------------------------------
-- The requirement says the practice the risk arrived with should already
-- be there, with its assets, when Risk Analysis opens. It does not say
-- somebody clicked anything to make that true. So the analysis screen
-- calls this on open, every time, and it must be safe to call on every
-- open forever:
--
--   * no linked practice        -> does nothing, returns quietly
--   * Primary already correct   -> does nothing
--   * Primary points elsewhere  -> the old Primary is demoted, not
--                                  deleted, because an analyst may have
--                                  since mapped it deliberately
--
-- That last case is the interesting one. linked_practice_id can change
-- (a later analysis re-derives it). Deleting the previous Primary would
-- silently drop assets the analyst may be relying on; demoting it to
-- Additional keeps everything and records that a human now owns the
-- decision to keep it.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_mapping_sync_primary
    @risk_register_id    BIGINT,
    @actor_employee_id   BIGINT        = NULL,
    @caller_display_name NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;

    IF @risk_register_id IS NULL
        THROW 56520, 'sp_risk_mapping_sync_primary: risk_register_id is required.', 1;

    DECLARE @org_id BIGINT, @practice_id BIGINT;
    SELECT @org_id = organization_id, @practice_id = linked_practice_id
      FROM grac_practice.risk_register
     WHERE risk_register_id = @risk_register_id;

    IF @org_id IS NULL
        THROW 56521, 'sp_risk_mapping_sync_primary: risk not found.', 1;

    -- No linked practice is a normal state, not an error: risks from
    -- sources that do not carry one get their practice from the picker.
    IF @practice_id IS NULL
    BEGIN
        SELECT CAST(0 AS BIT) AS Created, CAST(NULL AS BIGINT) AS PracticeId;
        RETURN;
    END

    -- Already Primary and correct -- the overwhelmingly common case, so
    -- it costs one indexed read and nothing else.
    IF EXISTS (SELECT 1 FROM grac_practice.risk_practice_map
                WHERE risk_register_id = @risk_register_id
                  AND practice_id      = @practice_id
                  AND map_source_code  = N'Primary')
    BEGIN
        SELECT CAST(0 AS BIT) AS Created, @practice_id AS PracticeId;
        RETURN;
    END

    -- Demote any other Primary before promoting this one:
    -- ux_pm_risk_practice_map_primary permits exactly one.
    UPDATE grac_practice.risk_practice_map
       SET map_source_code = N'Additional',
           updated_by      = @caller_display_name,
           updated_dt      = SYSUTCDATETIME()
     WHERE risk_register_id = @risk_register_id
       AND map_source_code  = N'Primary'
       AND practice_id     <> @practice_id;

    -- The practice may already be mapped as Additional -- an analyst got
    -- there before the derivation did. Promote in place rather than
    -- inserting, or uq_pm_risk_practice_map rejects the row.
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

    -- Delegate the insert AND the asset inheritance to the one procedure
    -- that knows how to do both. No second copy of that logic.
    EXEC grac_practice.sp_risk_practice_map
         @risk_register_id    = @risk_register_id,
         @practice_id         = @practice_id,
         @map_source_code     = N'Primary',
         @actor_employee_id   = @actor_employee_id,
         @caller_display_name = @caller_display_name;
END;
GO

-- =====================================================================
-- 3. sp_risk_practice_map   (requirement 2A / 2B)
--
-- Map a practice to a risk and inherit its dependency assets.
--
-- IDEMPOTENT BY DESIGN, at both grains:
--   * the practice row      -- uq_pm_risk_practice_map, and the NOT
--                              EXISTS guard that avoids provoking it
--   * the asset rows        -- uq_pm_risk_asset_map: one per (risk,asset)
--   * the contribution rows -- uq_pm_risk_asset_map_source
--
-- Mapping the same practice twice is therefore not an error to be
-- reported, it is a no-op to be absorbed. That matters because the
-- analysis screen re-syncs the Primary practice on every open, and a
-- screen that threw on its own second open would be unusable.
--
-- THE ASSET INSERT IS TWO STATEMENTS, NOT ONE MERGE
-- -------------------------------------------------
-- MERGE could do it in one, but it would have to write to two tables
-- (map and source) from one statement, which MERGE cannot do without an
-- OUTPUT ... INTO -- and OUTPUT ... INTO is exactly the construct that
-- fails the moment anybody puts a trigger on risk_asset_map. Two guarded
-- INSERTs are longer to read and cannot break that way.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_practice_map
    @risk_register_id    BIGINT,
    @practice_id         BIGINT,
    @map_source_code     NVARCHAR(20)  = N'Additional',
    @remarks             NVARCHAR(1000) = NULL,
    @actor_employee_id   BIGINT        = NULL,
    @caller_display_name NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;

    IF @risk_register_id IS NULL
        THROW 56522, 'sp_risk_practice_map: risk_register_id is required.', 1;
    IF @practice_id IS NULL
        THROW 56523, 'sp_risk_practice_map: practice_id is required.', 1;
    IF @map_source_code NOT IN (N'Primary', N'Additional')
        SET @map_source_code = N'Additional';

    DECLARE @org_id BIGINT, @status NVARCHAR(30), @risk_number NVARCHAR(60);
    SELECT @org_id      = organization_id,
           @status      = status_code,
           @risk_number = risk_number
      FROM grac_practice.risk_register
     WHERE risk_register_id = @risk_register_id;

    IF @org_id IS NULL
        THROW 56524, 'sp_risk_practice_map: risk not found.', 1;

    -- Same refusal 258 makes for residual scoring, for the same reason:
    -- editing the mapping of a terminal risk is almost always the wrong
    -- row rather than a deliberate act.
    IF @status IN (N'Closed', N'Retired')
        THROW 56525, 'sp_risk_practice_map: this risk is closed or retired -- reopen it before changing its practice mapping.', 1;

    -- Cross-organisation guard. A practice from another organisation on
    -- this risk would leak that organisation's asset names into this
    -- one's register, so it is refused rather than filtered.
    DECLARE @p_org BIGINT, @p_name NVARCHAR(300), @p_code NVARCHAR(100);
    SELECT @p_org  = organization_id,
           @p_name = practice_name,
           @p_code = practice_code
      FROM grac_practice.practice
     WHERE practice_id = @practice_id;

    IF @p_org IS NULL
        THROW 56526, 'sp_risk_practice_map: practice not found.', 1;
    IF @p_org <> @org_id
        THROW 56527, 'sp_risk_practice_map: that practice belongs to a different organisation.', 1;

    DECLARE @active_rs INT = (
        SELECT TOP 1 record_status_id FROM grac_practice.record_status_master
         WHERE status_code = N'Active' OR status_code = N'ACTIVE' OR status_name = N'Active'
         ORDER BY record_status_id);
    IF @active_rs IS NULL SET @active_rs = 1;

    DECLARE @created BIT = 0, @assets_added INT = 0, @sources_added INT = 0;

    BEGIN TRY
        BEGIN TRAN;

        -- ---- 3a. The practice row (validation case 1) ----------------
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

        -- ---- 3b. Asset rows this risk does not have yet --------------
        -- Validation cases 2 and 3: an asset already on the risk through
        -- another practice, or mapped directly, is NOT inserted again.
        -- The NOT EXISTS is what makes that true; the UNIQUE constraint
        -- is what makes it true even if this guard is ever wrong.
        INSERT INTO grac_practice.risk_asset_map
            (organization_id, risk_register_id, asset_id, asset_name,
             first_mapped_dt, mapped_by_employee_id,
             record_status_id, entered_by, entered_dt)
        SELECT @org_id, @risk_register_id, pa.AssetId, pa.AssetName,
               SYSUTCDATETIME(), @actor_employee_id,
               @active_rs, @caller_display_name, SYSUTCDATETIME()
          FROM grac_practice.fn_risk_practice_assets(@org_id, @practice_id) pa
         WHERE NOT EXISTS (SELECT 1 FROM grac_practice.risk_asset_map m
                            WHERE m.risk_register_id = @risk_register_id
                              AND m.asset_id         = pa.AssetId);

        SET @assets_added = @@ROWCOUNT;

        -- ---- 3c. The contribution rows ------------------------------
        -- Written for EVERY asset the practice reaches, including ones
        -- that were already on the risk. That is the whole point: the
        -- asset row says the asset is in scope, and the contribution
        -- rows say who would miss it if a practice were unmapped.
        INSERT INTO grac_practice.risk_asset_map_source
            (risk_asset_map_id, source_kind_code, practice_id,
             practice_instance_id, resolution_id,
             added_dt, added_by_employee_id, entered_by, entered_dt)
        SELECT m.risk_asset_map_id, N'PracticeDependency', @practice_id,
               pa.PracticeInstanceId, pa.ResolutionId,
               SYSUTCDATETIME(), @actor_employee_id,
               @caller_display_name, SYSUTCDATETIME()
          FROM grac_practice.fn_risk_practice_assets(@org_id, @practice_id) pa
          JOIN grac_practice.risk_asset_map m
            ON m.risk_register_id = @risk_register_id
           AND m.asset_id         = pa.AssetId
         WHERE NOT EXISTS (
                SELECT 1 FROM grac_practice.risk_asset_map_source s
                 WHERE s.risk_asset_map_id = m.risk_asset_map_id
                   AND s.source_kind_code  = N'PracticeDependency'
                   AND s.practice_id       = @practice_id);

        SET @sources_added = @@ROWCOUNT;

        -- Audit only when something actually changed. A re-sync on every
        -- screen open must not write a history row on every screen open.
        IF @created = 1 OR @assets_added > 0
            INSERT INTO grac_practice.risk_register_history
                (risk_register_id, action_code, from_status_code, to_status_code,
                 remark, actor_employee_id, actor_display_name, entered_by, entered_dt)
            VALUES
                (@risk_register_id, N'PracticeMapped', @status, @status,
                 CONCAT(N'Practice ', ISNULL(@p_name, CAST(@practice_id AS NVARCHAR(20))),
                        N' mapped as ', @map_source_code, N'. ',
                        CAST(@assets_added AS NVARCHAR(10)), N' asset(s) newly in scope.'),
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
           @assets_added     AS AssetsAdded,
           @sources_added    AS ContributionsAdded;
END;
GO

-- =====================================================================
-- 4. sp_risk_practice_unmap   (validation case 5)
--
-- "Removing an additional Practice should not blindly remove an Asset if
--  that Asset is still required by another mapped Practice or was
--  directly mapped."
--
-- The design makes this arithmetic rather than judgement:
--
--   1. delete THIS practice's contribution rows
--   2. delete asset rows that now have NO contribution rows at all
--
-- An asset kept by another practice still has that practice's
-- contribution, so step 2 passes it over. An asset the user mapped
-- directly still has its Direct contribution, so step 2 passes it over
-- too. Nothing has to ask "why is this here?" -- the rows answer.
--
-- ORDER MATTERS AND IS NOT INTERCHANGEABLE. Contributions first: they
-- reference the map row, and deleting the parent first fails on the FK.
--
-- THE PRIMARY PRACTICE CANNOT BE UNMAPPED HERE. It is the risk's own
-- linked_practice_id, and removing it through the mapping screen would
-- leave the register and the map disagreeing about what the risk is
-- attached to. Changing it is a register-level act.
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
        THROW 56528, 'sp_risk_practice_unmap: risk_register_id is required.', 1;
    IF @practice_id IS NULL
        THROW 56529, 'sp_risk_practice_unmap: practice_id is required.', 1;

    DECLARE @org_id BIGINT, @status NVARCHAR(30);
    SELECT @org_id = organization_id, @status = status_code
      FROM grac_practice.risk_register
     WHERE risk_register_id = @risk_register_id;

    IF @org_id IS NULL
        THROW 56530, 'sp_risk_practice_unmap: risk not found.', 1;
    IF @status IN (N'Closed', N'Retired')
        THROW 56531, 'sp_risk_practice_unmap: this risk is closed or retired -- reopen it before changing its practice mapping.', 1;

    DECLARE @map_source NVARCHAR(20), @p_name NVARCHAR(300);
    SELECT @map_source = map_source_code, @p_name = practice_name
      FROM grac_practice.risk_practice_map
     WHERE risk_register_id = @risk_register_id
       AND practice_id      = @practice_id;

    -- Unmapping something that is not mapped is a no-op, not a failure:
    -- two people clicking remove on the same row should not produce an
    -- error for the second one.
    IF @map_source IS NULL
    BEGIN
        SELECT @risk_register_id AS RiskRegisterId, @practice_id AS PracticeId,
               CAST(0 AS BIT) AS Removed, 0 AS AssetsRemoved, 0 AS AssetsKept;
        RETURN;
    END

    IF @map_source = N'Primary'
        THROW 56532, 'sp_risk_practice_unmap: this is the risk''s primary practice. Change the risk''s linked practice instead of unmapping it here.', 1;

    DECLARE @assets_removed INT = 0, @assets_kept INT = 0;

    BEGIN TRY
        BEGIN TRAN;

        -- ---- 4a. This practice's contributions ----------------------
        DELETE s
          FROM grac_practice.risk_asset_map_source s
          JOIN grac_practice.risk_asset_map m
            ON m.risk_asset_map_id = s.risk_asset_map_id
         WHERE m.risk_register_id  = @risk_register_id
           AND s.source_kind_code  = N'PracticeDependency'
           AND s.practice_id       = @practice_id;

        -- ---- 4b. Assets nothing vouches for any more -----------------
        DELETE m
          FROM grac_practice.risk_asset_map m
         WHERE m.risk_register_id = @risk_register_id
           AND NOT EXISTS (SELECT 1 FROM grac_practice.risk_asset_map_source s
                            WHERE s.risk_asset_map_id = m.risk_asset_map_id);

        SET @assets_removed = @@ROWCOUNT;

        DELETE FROM grac_practice.risk_practice_map
         WHERE risk_register_id = @risk_register_id
           AND practice_id      = @practice_id;

        SELECT @assets_kept = COUNT(*)
          FROM grac_practice.risk_asset_map
         WHERE risk_register_id = @risk_register_id;

        INSERT INTO grac_practice.risk_register_history
            (risk_register_id, action_code, from_status_code, to_status_code,
             remark, actor_employee_id, actor_display_name, entered_by, entered_dt)
        VALUES
            (@risk_register_id, N'PracticeUnmapped', @status, @status,
             CONCAT(N'Practice ', ISNULL(@p_name, CAST(@practice_id AS NVARCHAR(20))),
                    N' unmapped. ', CAST(@assets_removed AS NVARCHAR(10)),
                    N' asset(s) dropped, ', CAST(@assets_kept AS NVARCHAR(10)),
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
           @assets_removed   AS AssetsRemoved,
           @assets_kept      AS AssetsKept;
END;
GO

-- =====================================================================
-- 5. sp_risk_asset_map_direct   (requirement 2C, validation case 4)
--
-- "The user should also be able to map an Asset directly, even when that
--  Asset is not related to any of the Practices mapped to the risk."
--
-- No practice is asked for and none is inferred. The asset row is
-- created if this risk does not have it, and a Direct contribution is
-- added either way -- so an asset that arrived through a practice and is
-- then ALSO mapped directly ends up with two contributions and survives
-- that practice being unmapped. That is not an edge case to tolerate, it
-- is the mechanism by which "I want this one kept regardless" works.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_asset_map_direct
    @risk_register_id    BIGINT,
    @asset_id            BIGINT,
    @remarks             NVARCHAR(1000) = NULL,
    @actor_employee_id   BIGINT        = NULL,
    @caller_display_name NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;

    IF @risk_register_id IS NULL
        THROW 56533, 'sp_risk_asset_map_direct: risk_register_id is required.', 1;
    IF @asset_id IS NULL
        THROW 56534, 'sp_risk_asset_map_direct: asset_id is required.', 1;

    DECLARE @org_id BIGINT, @status NVARCHAR(30);
    SELECT @org_id = organization_id, @status = status_code
      FROM grac_practice.risk_register
     WHERE risk_register_id = @risk_register_id;

    IF @org_id IS NULL
        THROW 56535, 'sp_risk_asset_map_direct: risk not found.', 1;
    IF @status IN (N'Closed', N'Retired')
        THROW 56536, 'sp_risk_asset_map_direct: this risk is closed or retired -- reopen it before changing its asset mapping.', 1;

    DECLARE @a_org BIGINT, @a_name NVARCHAR(220);
    SELECT @a_org = organization_id, @a_name = asset_name
      FROM grac_practice.organization_dependency_asset
     WHERE asset_id = @asset_id;

    IF @a_org IS NULL
        THROW 56537, 'sp_risk_asset_map_direct: asset not found.', 1;
    IF @a_org <> @org_id
        THROW 56538, 'sp_risk_asset_map_direct: that asset belongs to a different organisation.', 1;

    DECLARE @active_rs INT = (
        SELECT TOP 1 record_status_id FROM grac_practice.record_status_master
         WHERE status_code = N'Active' OR status_code = N'ACTIVE' OR status_name = N'Active'
         ORDER BY record_status_id);
    IF @active_rs IS NULL SET @active_rs = 1;

    DECLARE @map_id BIGINT, @created BIT = 0, @source_added BIT = 0;

    BEGIN TRY
        BEGIN TRAN;

        SELECT @map_id = risk_asset_map_id
          FROM grac_practice.risk_asset_map
         WHERE risk_register_id = @risk_register_id
           AND asset_id         = @asset_id;

        IF @map_id IS NULL
        BEGIN
            INSERT INTO grac_practice.risk_asset_map
                (organization_id, risk_register_id, asset_id, asset_name,
                 first_mapped_dt, mapped_by_employee_id, remarks,
                 record_status_id, entered_by, entered_dt)
            VALUES
                (@org_id, @risk_register_id, @asset_id, @a_name,
                 SYSUTCDATETIME(), @actor_employee_id, @remarks,
                 @active_rs, @caller_display_name, SYSUTCDATETIME());

            SET @map_id  = SCOPE_IDENTITY();
            SET @created = 1;
        END

        IF NOT EXISTS (SELECT 1 FROM grac_practice.risk_asset_map_source
                        WHERE risk_asset_map_id = @map_id
                          AND source_kind_code  = N'Direct')
        BEGIN
            INSERT INTO grac_practice.risk_asset_map_source
                (risk_asset_map_id, source_kind_code, practice_id,
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
                (@risk_register_id, N'AssetMapped', @status, @status,
                 CONCAT(N'Asset ', ISNULL(@a_name, CAST(@asset_id AS NVARCHAR(20))),
                        N' mapped directly (no practice).'),
                 @actor_employee_id, @caller_display_name,
                 @caller_display_name, SYSUTCDATETIME());

        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH

    SELECT @risk_register_id AS RiskRegisterId,
           @map_id           AS RiskAssetMapId,
           @asset_id         AS AssetId,
           @a_name           AS AssetName,
           @created          AS Created;
END;
GO

-- =====================================================================
-- 6. sp_risk_asset_unmap
--
-- Removes the DIRECT reason for an asset being on a risk. The mirror of
-- section 4, and it obeys the same arithmetic: the asset row goes only
-- when no contribution of any kind survives.
--
-- So removing a directly-mapped asset that is ALSO reached by a mapped
-- practice leaves it on the risk, correctly relabelled as inherited.
-- The screen must say so rather than appearing to ignore the click,
-- which is why AssetRemoved and RemainingSources are both returned.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_asset_unmap
    @risk_register_id    BIGINT,
    @asset_id            BIGINT,
    @actor_employee_id   BIGINT        = NULL,
    @caller_display_name NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;

    IF @risk_register_id IS NULL
        THROW 56539, 'sp_risk_asset_unmap: risk_register_id is required.', 1;
    IF @asset_id IS NULL
        THROW 56540, 'sp_risk_asset_unmap: asset_id is required.', 1;

    DECLARE @org_id BIGINT, @status NVARCHAR(30);
    SELECT @org_id = organization_id, @status = status_code
      FROM grac_practice.risk_register
     WHERE risk_register_id = @risk_register_id;

    IF @org_id IS NULL
        THROW 56541, 'sp_risk_asset_unmap: risk not found.', 1;
    IF @status IN (N'Closed', N'Retired')
        THROW 56542, 'sp_risk_asset_unmap: this risk is closed or retired -- reopen it before changing its asset mapping.', 1;

    DECLARE @map_id BIGINT, @a_name NVARCHAR(220);
    SELECT @map_id = risk_asset_map_id, @a_name = asset_name
      FROM grac_practice.risk_asset_map
     WHERE risk_register_id = @risk_register_id
       AND asset_id         = @asset_id;

    IF @map_id IS NULL
    BEGIN
        SELECT @risk_register_id AS RiskRegisterId, @asset_id AS AssetId,
               CAST(0 AS BIT) AS AssetRemoved, 0 AS RemainingSources;
        RETURN;
    END

    DECLARE @remaining INT = 0, @removed BIT = 0;

    BEGIN TRY
        BEGIN TRAN;

        DELETE FROM grac_practice.risk_asset_map_source
         WHERE risk_asset_map_id = @map_id
           AND source_kind_code  = N'Direct';

        SELECT @remaining = COUNT(*)
          FROM grac_practice.risk_asset_map_source
         WHERE risk_asset_map_id = @map_id;

        IF @remaining = 0
        BEGIN
            DELETE FROM grac_practice.risk_asset_map
             WHERE risk_asset_map_id = @map_id;
            SET @removed = 1;
        END

        INSERT INTO grac_practice.risk_register_history
            (risk_register_id, action_code, from_status_code, to_status_code,
             remark, actor_employee_id, actor_display_name, entered_by, entered_dt)
        VALUES
            (@risk_register_id, N'AssetUnmapped', @status, @status,
             CONCAT(N'Direct mapping removed for asset ',
                    ISNULL(@a_name, CAST(@asset_id AS NVARCHAR(20))), N'. ',
                    CASE WHEN @removed = 1
                         THEN N'Asset removed from the risk.'
                         ELSE CONCAT(N'Asset retained -- still reached by ',
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

    SELECT @risk_register_id AS RiskRegisterId,
           @asset_id         AS AssetId,
           @removed          AS AssetRemoved,
           @remaining        AS RemainingSources;
END;
GO

-- =====================================================================
-- 7. sp_risk_mapping_get
--
-- Two result sets, in the order the screen renders them: practices, then
-- assets. One round trip, matching how every other Risk Centre detail
-- read already behaves.
--
-- THE ASSET SET CARRIES ITS OWN PROVENANCE
-- ----------------------------------------
-- The requirement asks the UI to distinguish assets inherited from the
-- primary practice, assets inherited from additional practices, and
-- assets mapped directly. Making the CLIENT work that out means shipping
-- it the contribution rows and asking JavaScript to reduce them, which
-- is both slower and a second place for the rule to be wrong.
--
-- So the classification is computed here, once, in SQL:
--
--   Direct              at least one Direct contribution and no
--                       practice contribution -- purely a human choice
--   Primary             reached by the risk's primary practice
--   Additional          reached only by additional practices
--   DirectAndInherited  both -- a human pinned an asset that a practice
--                       also happens to reach
--
-- SourcePractices is the human-readable "why", built with STRING_AGG,
-- which is the same construct 141 uses for the same job. It is a
-- correlated aggregate in the SELECT list rather than inside another
-- aggregate, so it does not trip Msg 130.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_mapping_get
    @risk_register_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    IF @risk_register_id IS NULL
        THROW 56543, 'sp_risk_mapping_get: risk_register_id is required.', 1;

    DECLARE @org_id BIGINT, @primary_practice_id BIGINT;
    SELECT @org_id = organization_id
      FROM grac_practice.risk_register
     WHERE risk_register_id = @risk_register_id;

    IF @org_id IS NULL
        THROW 56544, 'sp_risk_mapping_get: risk not found.', 1;

    SELECT @primary_practice_id = practice_id
      FROM grac_practice.risk_practice_map
     WHERE risk_register_id = @risk_register_id
       AND map_source_code  = N'Primary';

    -- ---- Result set 1: mapped practices ------------------------------
    -- AssetCount is the number of assets on THIS RISK that this practice
    -- vouches for -- not the number the practice depends on. Those differ
    -- when an asset was already present, and the risk-scoped number is
    -- the one that tells the user what unmapping would risk.
    SELECT pm.risk_practice_map_id       AS RiskPracticeMapId,
           pm.practice_id                AS PracticeId,
           COALESCE(p.practice_name, pm.practice_name) AS PracticeName,
           COALESCE(p.practice_code, pm.practice_code) AS PracticeCode,
           pm.map_source_code            AS MapSourceCode,
           CAST(CASE WHEN pm.map_source_code = N'Primary' THEN 1 ELSE 0 END AS BIT)
                                         AS IsPrimary,
           pm.mapped_dt                  AS MappedDt,
           pm.mapped_by_employee_id      AS MappedByEmployeeId,
           e.employee_name               AS MappedByName,
           pm.remarks                    AS Remarks,
           (SELECT COUNT(*)
              FROM grac_practice.risk_asset_map_source s
              JOIN grac_practice.risk_asset_map m
                ON m.risk_asset_map_id = s.risk_asset_map_id
             WHERE m.risk_register_id = @risk_register_id
               AND s.practice_id      = pm.practice_id) AS AssetCount
      FROM grac_practice.risk_practice_map pm
      LEFT JOIN grac_practice.practice p
        ON p.practice_id = pm.practice_id
      LEFT JOIN grac_practice.organization_employee e
        ON e.employee_id = pm.mapped_by_employee_id
     WHERE pm.risk_register_id = @risk_register_id
     ORDER BY CASE WHEN pm.map_source_code = N'Primary' THEN 0 ELSE 1 END,
              COALESCE(p.practice_name, pm.practice_name);

    -- ---- Result set 2: mapped assets, with provenance ----------------
    SELECT m.risk_asset_map_id           AS RiskAssetMapId,
           m.asset_id                    AS AssetId,
           COALESCE(a.asset_name, m.asset_name) AS AssetName,
           ac.asset_category_name        AS AssetCategoryName,
           cr.criticality_name           AS Criticality,
           m.first_mapped_dt             AS FirstMappedDt,
           m.remarks                     AS Remarks,

           CAST(CASE WHEN EXISTS (SELECT 1 FROM grac_practice.risk_asset_map_source s
                                   WHERE s.risk_asset_map_id = m.risk_asset_map_id
                                     AND s.source_kind_code  = N'Direct')
                     THEN 1 ELSE 0 END AS BIT)               AS IsDirect,
           CAST(CASE WHEN EXISTS (SELECT 1 FROM grac_practice.risk_asset_map_source s
                                   WHERE s.risk_asset_map_id = m.risk_asset_map_id
                                     AND s.source_kind_code  = N'PracticeDependency')
                     THEN 1 ELSE 0 END AS BIT)               AS IsInherited,
           CAST(CASE WHEN @primary_practice_id IS NOT NULL
                      AND EXISTS (SELECT 1 FROM grac_practice.risk_asset_map_source s
                                   WHERE s.risk_asset_map_id = m.risk_asset_map_id
                                     AND s.practice_id       = @primary_practice_id)
                     THEN 1 ELSE 0 END AS BIT)               AS FromPrimaryPractice,

           -- The single label the grid shows. See the header for the
           -- four values and what each means.
           CASE
             WHEN EXISTS (SELECT 1 FROM grac_practice.risk_asset_map_source s
                           WHERE s.risk_asset_map_id = m.risk_asset_map_id
                             AND s.source_kind_code  = N'Direct')
              AND EXISTS (SELECT 1 FROM grac_practice.risk_asset_map_source s
                           WHERE s.risk_asset_map_id = m.risk_asset_map_id
                             AND s.source_kind_code  = N'PracticeDependency')
                  THEN N'DirectAndInherited'
             WHEN EXISTS (SELECT 1 FROM grac_practice.risk_asset_map_source s
                           WHERE s.risk_asset_map_id = m.risk_asset_map_id
                             AND s.source_kind_code  = N'Direct')
                  THEN N'Direct'
             WHEN @primary_practice_id IS NOT NULL
              AND EXISTS (SELECT 1 FROM grac_practice.risk_asset_map_source s
                           WHERE s.risk_asset_map_id = m.risk_asset_map_id
                             AND s.practice_id       = @primary_practice_id)
                  THEN N'Primary'
             ELSE N'Additional'
           END                                               AS SourceLabel,

           (SELECT COUNT(*) FROM grac_practice.risk_asset_map_source s
             WHERE s.risk_asset_map_id = m.risk_asset_map_id) AS SourceCount,

           -- "Why is this asset here?", in one cell.
           (SELECT STRING_AGG(CONVERT(NVARCHAR(MAX),
                       COALESCE(pp.practice_name, pm2.practice_name)), N', ')
              FROM grac_practice.risk_asset_map_source s2
              LEFT JOIN grac_practice.practice pp
                ON pp.practice_id = s2.practice_id
              LEFT JOIN grac_practice.risk_practice_map pm2
                ON pm2.risk_register_id = @risk_register_id
               AND pm2.practice_id      = s2.practice_id
             WHERE s2.risk_asset_map_id = m.risk_asset_map_id
               AND s2.source_kind_code  = N'PracticeDependency') AS SourcePractices
      FROM grac_practice.risk_asset_map m
      LEFT JOIN grac_practice.organization_dependency_asset a
        ON a.asset_id = m.asset_id
      LEFT JOIN grac_practice.dependency_asset_category_master ac
        ON ac.asset_category_id = a.asset_category_id
      LEFT JOIN grac_practice.criticality_master cr
        ON cr.criticality_id = a.criticality_id
     WHERE m.risk_register_id = @risk_register_id
     ORDER BY COALESCE(a.asset_name, m.asset_name);
END;
GO

-- =====================================================================
-- 8. sp_risk_mapping_options
--
-- The two picklists the mapping panel needs, already filtered to what is
-- mappable: practices this risk does NOT have, and assets this risk does
-- NOT have. Offering something the constraints will reject is a worse
-- experience than not offering it, and filtering here means the client
-- never has to subtract one list from another.
--
-- AssetsFromPractices is returned for each practice so the picker can
-- tell the user what mapping it will pull in BEFORE they commit -- the
-- difference between "map this practice" and "map this practice and 14
-- assets you have not seen" matters at the moment of clicking.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_mapping_options
    @risk_register_id BIGINT,
    @search           NVARCHAR(200) = NULL,
    @top              INT           = 200
AS
BEGIN
    SET NOCOUNT ON;

    IF @risk_register_id IS NULL
        THROW 56545, 'sp_risk_mapping_options: risk_register_id is required.', 1;
    IF @top IS NULL OR @top <= 0 OR @top > 1000 SET @top = 200;

    DECLARE @org_id BIGINT;
    SELECT @org_id = organization_id
      FROM grac_practice.risk_register
     WHERE risk_register_id = @risk_register_id;

    IF @org_id IS NULL
        THROW 56546, 'sp_risk_mapping_options: risk not found.', 1;

    DECLARE @like NVARCHAR(210) =
        CASE WHEN @search IS NULL OR LEN(LTRIM(RTRIM(@search))) = 0
             THEN NULL ELSE N'%' + LTRIM(RTRIM(@search)) + N'%' END;

    -- ---- Result set 1: mappable practices ----------------------------
    SELECT TOP (@top)
           p.practice_id    AS PracticeId,
           p.practice_name  AS PracticeName,
           p.practice_code  AS PracticeCode,
           (SELECT COUNT(*) FROM grac_practice.fn_risk_practice_assets(@org_id, p.practice_id))
                            AS AssetsFromPractice
      FROM grac_practice.practice p
     WHERE p.organization_id = @org_id
       AND p.status = N'Active'
       AND (@like IS NULL OR p.practice_name LIKE @like OR p.practice_code LIKE @like)
       AND NOT EXISTS (SELECT 1 FROM grac_practice.risk_practice_map pm
                        WHERE pm.risk_register_id = @risk_register_id
                          AND pm.practice_id      = p.practice_id)
     ORDER BY p.practice_name;

    -- ---- Result set 2: mappable assets -------------------------------
    SELECT TOP (@top)
           a.asset_id              AS AssetId,
           a.asset_name            AS AssetName,
           ac.asset_category_name  AS AssetCategoryName,
           cr.criticality_name     AS Criticality
      FROM grac_practice.organization_dependency_asset a
      LEFT JOIN grac_practice.dependency_asset_category_master ac
        ON ac.asset_category_id = a.asset_category_id
      LEFT JOIN grac_practice.criticality_master cr
        ON cr.criticality_id = a.criticality_id
     WHERE a.organization_id = @org_id
       AND a.status = N'Active'
       AND (@like IS NULL OR a.asset_name LIKE @like)
       AND NOT EXISTS (SELECT 1 FROM grac_practice.risk_asset_map m
                        WHERE m.risk_register_id = @risk_register_id
                          AND m.asset_id         = a.asset_id)
     ORDER BY a.asset_name;
END;
GO

-- =====================================================================
-- Sanity
-- =====================================================================
SELECT '262 objects present' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.fn_risk_practice_assets','IF')  IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_risk_mapping_sync_primary','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_risk_practice_map','P')      IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_risk_practice_unmap','P')    IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_risk_asset_map_direct','P')  IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_risk_asset_unmap','P')       IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_risk_mapping_get','P')       IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_risk_mapping_options','P')   IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;

-- fn_risk_practice_assets must be INLINE ('IF'), not multi-statement
-- ('TF'). If a later edit turns it into a multi-statement function the
-- procedures above keep working and silently get much slower, so the
-- distinction is asserted rather than assumed.
SELECT '262 asset function is inline' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.fn_risk_practice_assets','IF') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;

PRINT '262 Risk practice/asset mapping procedures installed.';
PRINT '     One asset row per (risk, asset); the reasons live in risk_asset_map_source.';
PRINT '     Unmapping a practice removes only the assets nothing else vouches for.';
GO

SET NOEXEC OFF;
GO
