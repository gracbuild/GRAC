-- =====================================================================
-- 245 Persistent gap tables + per-instance sync
--
-- WHAT AND WHY
-- ------------
-- Migration 243 gave Task Center a *derived* gap list -- a view that
-- computes the effective implementation status from the obligation rows
-- and reports it live. That was enough to render the page, but it never
-- answered
--
--   * when did this gap first appear
--   * who logged which offending obligation, in what order
--   * has this gap been officially closed or is it just quiet right now
--
-- The user asked for the second form: when an obligation is saved and
-- comes out Not Implemented / Partially Implemented, either APPEND its
-- details to an existing gap for the practice instance, or OPEN a new
-- one. When it later moves to Implemented / N/A, remove its row from
-- the gap; when the last offending row goes, close the gap.
--
-- Two new tables carry that state, one procedure keeps them in sync
-- with the current obligation rows, and sp_task_center_gaps_list is
-- re-emitted to read from them instead of the derived view.
--
--   practice_gap                 : one row per practice_instance;
--                                  opened_dt / closed_dt / gap_status.
--   practice_gap_obligation      : one active row per offending
--                                  obligation; retired (status =
--                                  'Retired', removed_dt) when the
--                                  obligation moves out of gap
--                                  territory. Kept, not deleted, so
--                                  the "who was in the gap when"
--                                  question has an answer.
--
-- The sync procedure sp_practice_gap_sync_for_instance is called from
-- the API tier right after every obligation save (bulk adopt or single
-- local save). It is idempotent and reads current state, so a repeated
-- call is a no-op.
--
-- vw_pm_instance_effective_impl_status (243) is left in place. Nothing
-- else reads it after this migration; keeping it costs nothing and lets
-- a caller who wants the live rollup outside of Task Center still get
-- it in one row per instance.
--
-- SAFE TO RE-RUN. Requires 242 (implementation_status_id column) and
-- 243 (effective-status view -- consumed by the initial backfill).
-- ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    PRINT 'ABORT (245): schema grac_practice missing.';
    SET NOEXEC ON;
END
GO

IF COL_LENGTH('grac_practice.practice_instance_obligation','implementation_status_id') IS NULL
BEGIN
    PRINT 'ABORT (245): implementation_status_id column missing -- run 242 first.';
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. practice_gap  -- one row per practice_instance
-- =====================================================================
IF OBJECT_ID('grac_practice.practice_gap','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.practice_gap (
        practice_gap_id      BIGINT IDENTITY(1,1) NOT NULL
            CONSTRAINT pk_pm_practice_gap PRIMARY KEY,
        organization_id      BIGINT       NOT NULL
            CONSTRAINT fk_pm_practice_gap_org
                REFERENCES grac_practice.organization(organization_id),
        practice_instance_id BIGINT       NOT NULL
            CONSTRAINT fk_pm_practice_gap_pi
                REFERENCES grac_practice.practice_instance(practice_instance_id),
        gap_status           NVARCHAR(20) NOT NULL
            CONSTRAINT df_pm_practice_gap_status DEFAULT (N'Open'),
        -- The first time the gap was opened. It is not reset when the
        -- gap is closed and later reopened -- see reopened_dt for that.
        opened_dt            DATETIME2(3) NOT NULL
            CONSTRAINT df_pm_practice_gap_opened DEFAULT (SYSUTCDATETIME()),
        closed_dt            DATETIME2(3) NULL,
        -- Populated when the sync moves the parent back from Closed to
        -- Open. Distinguishes "always been open" from "closed then a new
        -- obligation slipped" without a second history table.
        reopened_dt          DATETIME2(3) NULL,
        entered_by           NVARCHAR(100) NULL,
        entered_dt           DATETIME2(3) NOT NULL
            CONSTRAINT df_pm_practice_gap_entered DEFAULT (SYSUTCDATETIME()),
        updated_by           NVARCHAR(100) NULL,
        updated_dt           DATETIME2(3) NULL,
        -- ONE gap per practice instance -- the user's rule ("aa practice
        -- instance nte against oru gap already register cheythittundo").
        CONSTRAINT uq_pm_practice_gap_instance UNIQUE (practice_instance_id),
        CONSTRAINT ck_pm_practice_gap_status
            CHECK (gap_status IN (N'Open', N'Closed'))
    );
    CREATE INDEX ix_pm_practice_gap_org_status
        ON grac_practice.practice_gap(organization_id, gap_status)
        INCLUDE (practice_instance_id);
    PRINT '245: practice_gap created.';
END
GO

-- =====================================================================
-- 2. practice_gap_obligation  -- child rows per offending obligation
-- =====================================================================
IF OBJECT_ID('grac_practice.practice_gap_obligation','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.practice_gap_obligation (
        practice_gap_obligation_id      BIGINT IDENTITY(1,1) NOT NULL
            CONSTRAINT pk_pm_practice_gap_obligation PRIMARY KEY,
        practice_gap_id                 BIGINT       NOT NULL
            CONSTRAINT fk_pm_practice_gap_obligation_gap
                REFERENCES grac_practice.practice_gap(practice_gap_id),
        practice_instance_obligation_id BIGINT       NOT NULL
            CONSTRAINT fk_pm_practice_gap_obligation_pio
                REFERENCES grac_practice.practice_instance_obligation(practice_instance_obligation_id),
        -- Snapshot of the obligation identity at the moment it entered
        -- the gap, so a later rename on the obligation does not silently
        -- rewrite what the gap history said.
        obligation_name                 NVARCHAR(500) NULL,
        obligation_type_code            NVARCHAR(60)  NULL,
        -- The status that put this row in the gap -- Not Implemented or
        -- Partially Implemented. Snapshot so a later transition to
        -- something else does not overwrite the reason it was listed.
        logged_status_code              NVARCHAR(60)  NOT NULL,
        added_dt                        DATETIME2(3)  NOT NULL
            CONSTRAINT df_pm_practice_gap_obligation_added DEFAULT (SYSUTCDATETIME()),
        removed_dt                      DATETIME2(3)  NULL,
        -- Active while the obligation is in gap territory; Retired the
        -- moment it moves to Implemented / N/A. Retired rows STAY --
        -- audit trail is the whole point of the child table -- so the
        -- unique-per-obligation constraint is scoped to Active.
        status                          NVARCHAR(20)  NOT NULL
            CONSTRAINT df_pm_practice_gap_obligation_status DEFAULT (N'Active'),
        entered_by                      NVARCHAR(100) NULL,
        entered_dt                      DATETIME2(3)  NOT NULL
            CONSTRAINT df_pm_practice_gap_obligation_entered DEFAULT (SYSUTCDATETIME()),
        updated_by                      NVARCHAR(100) NULL,
        updated_dt                      DATETIME2(3)  NULL,
        CONSTRAINT ck_pm_practice_gap_obligation_status
            CHECK (status IN (N'Active', N'Retired')),
        CONSTRAINT ck_pm_practice_gap_obligation_logged
            CHECK (logged_status_code IN (N'Not Implemented', N'Partially Implemented'))
    );

    -- One Active row per (gap, obligation). Retired rows do NOT block,
    -- so an obligation can re-enter the gap after being resolved and
    -- get a fresh row rather than reviving stale metadata.
    CREATE UNIQUE INDEX uq_pm_practice_gap_obligation_active
        ON grac_practice.practice_gap_obligation(practice_gap_id, practice_instance_obligation_id)
        WHERE status = N'Active';

    CREATE INDEX ix_pm_practice_gap_obligation_gap
        ON grac_practice.practice_gap_obligation(practice_gap_id, status)
        INCLUDE (practice_instance_obligation_id, logged_status_code, added_dt);
    PRINT '245: practice_gap_obligation created.';
END
GO

-- =====================================================================
-- 3. sp_practice_gap_sync_for_instance
--
-- Reconciles the two tables above with what the practice_instance_obligation
-- rows currently say. Called from the API tier after every obligation
-- save. Idempotent.
--
-- Contract
-- --------
--   * ADD    active child rows for any obligation whose current status
--            is Not Implemented / Partially Implemented and which is
--            not already logged as Active on the gap.
--   * RETIRE active child rows whose obligation is no longer in gap
--            territory (Implemented / N/A / no status).
--   * Ensure a practice_gap row exists when there is at least one
--            Active child; open it if it was Closed, and record
--            reopened_dt.
--   * CLOSE the practice_gap when no Active children remain.
--
-- Never DELETES a child -- the retired row is the audit trail. The
-- unique-per-Active index means a re-entry after retirement is a new
-- child, not an update, so the added_dt reflects when THIS occurrence
-- began.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_practice_gap_sync_for_instance
    @practice_instance_id BIGINT,
    @actor                NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @practice_instance_id IS NULL
        THROW 52720, 'sp_practice_gap_sync_for_instance: practice_instance_id is required.', 1;

    DECLARE @organization_id BIGINT;
    SELECT @organization_id = organization_id
    FROM   grac_practice.practice_instance
    WHERE  practice_instance_id = @practice_instance_id;

    IF @organization_id IS NULL
        THROW 52721, 'sp_practice_gap_sync_for_instance: instance not found.', 1;

    -- Current gap-territory obligations for this instance. NULL status
    -- reads as "Not Started" per the 243 rule, but Not Started is NOT
    -- a gap on its own -- only explicit Not Implemented / Partially
    -- Implemented are.
    DECLARE @current TABLE (
        practice_instance_obligation_id BIGINT PRIMARY KEY,
        obligation_name                 NVARCHAR(500) NULL,
        obligation_type_code            NVARCHAR(60)  NULL,
        status_code                     NVARCHAR(60)  NOT NULL
    );

    INSERT INTO @current
        (practice_instance_obligation_id, obligation_name, obligation_type_code, status_code)
    SELECT pio.practice_instance_obligation_id,
           pio.obligation_name,
           pio.obligation_type_code,
           ims.status_code
    FROM   grac_practice.practice_instance_obligation pio
    JOIN   grac_practice.implementation_status_master ims
           ON ims.implementation_status_id = pio.implementation_status_id
    WHERE  pio.practice_instance_id = @practice_instance_id
      AND  pio.status               = N'Active'
      AND  ims.status_code IN (N'Not Implemented', N'Partially Implemented');

    BEGIN TRAN;

    -- Ensure the parent row exists. Insert only when there is at least
    -- one current gap-territory obligation -- do not create an empty
    -- Closed gap just because the instance had no obligations.
    IF NOT EXISTS (SELECT 1 FROM grac_practice.practice_gap
                    WHERE practice_instance_id = @practice_instance_id)
       AND EXISTS (SELECT 1 FROM @current)
    BEGIN
        INSERT grac_practice.practice_gap
            (organization_id, practice_instance_id, gap_status,
             opened_dt, entered_by)
        VALUES
            (@organization_id, @practice_instance_id, N'Open',
             SYSUTCDATETIME(), @actor);
    END

    DECLARE @practice_gap_id BIGINT;
    SELECT @practice_gap_id = practice_gap_id
    FROM   grac_practice.practice_gap
    WHERE  practice_instance_id = @practice_instance_id;

    -- 3a. Retire any active child whose obligation is no longer in gap
    --     territory. Cast covers "status moved to Implemented / N/A"
    --     AND "obligation was retired from the instance".
    IF @practice_gap_id IS NOT NULL
    BEGIN
        UPDATE pgo
           SET status     = N'Retired',
               removed_dt = SYSUTCDATETIME(),
               updated_by = @actor,
               updated_dt = SYSUTCDATETIME()
        FROM   grac_practice.practice_gap_obligation pgo
        WHERE  pgo.practice_gap_id = @practice_gap_id
          AND  pgo.status          = N'Active'
          AND  NOT EXISTS (SELECT 1 FROM @current c
                            WHERE c.practice_instance_obligation_id
                                = pgo.practice_instance_obligation_id);
    END

    -- 3b. Add active children for any current gap-territory obligation
    --     that has no active row yet. The partial unique index above
    --     already prevents duplicates; NOT EXISTS also skips the check
    --     when the row is there.
    IF @practice_gap_id IS NOT NULL
    BEGIN
        INSERT grac_practice.practice_gap_obligation
            (practice_gap_id, practice_instance_obligation_id,
             obligation_name, obligation_type_code,
             logged_status_code, status, entered_by)
        SELECT @practice_gap_id, c.practice_instance_obligation_id,
               c.obligation_name, c.obligation_type_code,
               c.status_code, N'Active', @actor
        FROM   @current c
        WHERE  NOT EXISTS (SELECT 1 FROM grac_practice.practice_gap_obligation pgo
                            WHERE pgo.practice_gap_id = @practice_gap_id
                              AND pgo.practice_instance_obligation_id
                                  = c.practice_instance_obligation_id
                              AND pgo.status = N'Active');

        -- 3c. Recompute parent gap_status. Close when no actives remain,
        --     Open (with reopened_dt on transitions Closed -> Open) when
        --     any active row exists.
        DECLARE @active_count INT = (
            SELECT COUNT(*) FROM grac_practice.practice_gap_obligation
             WHERE practice_gap_id = @practice_gap_id
               AND status          = N'Active');

        IF @active_count = 0
        BEGIN
            UPDATE grac_practice.practice_gap
               SET gap_status = N'Closed',
                   closed_dt  = SYSUTCDATETIME(),
                   updated_by = @actor,
                   updated_dt = SYSUTCDATETIME()
             WHERE practice_gap_id = @practice_gap_id
               AND gap_status      = N'Open';
        END
        ELSE
        BEGIN
            UPDATE grac_practice.practice_gap
               SET gap_status  = N'Open',
                   -- Only stamp reopened_dt on an actual Closed -> Open
                   -- transition; the current UPDATE clause runs on both.
                   reopened_dt = CASE WHEN gap_status = N'Closed'
                                      THEN SYSUTCDATETIME()
                                      ELSE reopened_dt END,
                   closed_dt   = NULL,
                   updated_by  = @actor,
                   updated_dt  = SYSUTCDATETIME()
             WHERE practice_gap_id = @practice_gap_id;
        END
    END

    COMMIT TRAN;

    -- Small result set so the API tier can log the outcome.
    SELECT @practice_instance_id  AS PracticeInstanceId,
           @practice_gap_id       AS PracticeGapId,
           (SELECT gap_status FROM grac_practice.practice_gap
             WHERE practice_gap_id = @practice_gap_id) AS GapStatus,
           (SELECT COUNT(*) FROM grac_practice.practice_gap_obligation
             WHERE practice_gap_id = @practice_gap_id AND status = N'Active') AS ActiveObligationCount;
END
GO
PRINT '245: sp_practice_gap_sync_for_instance ready.';
GO

-- =====================================================================
-- 4. Backfill from the derived view (one-off, safe to re-run)
--
-- On first apply the persistent tables are empty; every instance the
-- 243 view already flagged as in gap territory needs a row so the Task
-- Center numbers do not go blank until an operator saves each one. Runs
-- the same sync procedure per instance, which is idempotent.
-- =====================================================================
IF OBJECT_ID('grac_practice.vw_pm_instance_effective_impl_status','V') IS NOT NULL
BEGIN
    DECLARE @backfill_id BIGINT;
    DECLARE backfill CURSOR LOCAL FAST_FORWARD FOR
        SELECT DISTINCT eff.PracticeInstanceId
        FROM   grac_practice.vw_pm_instance_effective_impl_status eff
        WHERE  eff.StatusCode IN (N'Not Implemented', N'Partially Implemented');

    OPEN backfill;
    FETCH NEXT FROM backfill INTO @backfill_id;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        EXEC grac_practice.sp_practice_gap_sync_for_instance
             @practice_instance_id = @backfill_id,
             @actor                = N'backfill-245';
        FETCH NEXT FROM backfill INTO @backfill_id;
    END
    CLOSE backfill;
    DEALLOCATE backfill;
    PRINT '245: backfill complete.';
END
GO

-- =====================================================================
-- 5. sp_task_center_gaps_list -- re-emitted to read from practice_gap
--
-- Same signature and column contract as 243. GapObligationsJson now
-- comes from practice_gap_obligation active rows -- so the expansion
-- lists the obligations *this gap actually logged*, not whatever the
-- current obligation table looks like. That matters because a snapshot
-- carries obligation_name at the moment it entered the gap.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_task_center_gaps_list
    @organization_id BIGINT,
    @search          NVARCHAR(200) = NULL,
    @page            INT           = 1,
    @page_size       INT           = 25
AS
BEGIN
    SET NOCOUNT ON;
    IF @page IS NULL OR @page < 1 SET @page = 1;
    IF @page_size IS NULL OR @page_size < 1 SET @page_size = 25;
    IF @page_size > 200 SET @page_size = 200;

    DECLARE @results TABLE (
        PracticeInstanceId    BIGINT,
        PracticeGapId         BIGINT,
        InstanceCode          NVARCHAR(100),
        InstanceName          NVARCHAR(300),
        PracticeId            BIGINT NULL,
        PracticeCode          NVARCHAR(100) NULL,
        PracticeName          NVARCHAR(300) NULL,
        OrganizationId        BIGINT NULL,
        OrganizationName      NVARCHAR(300) NULL,
        -- Instance-level implementation status projection kept as a
        -- convenience; it is the WORST of the active child statuses so
        -- a caller who wants a single word still gets one.
        ImplementationStatus  NVARCHAR(60),
        GapObligationCount    INT NOT NULL,
        Owner                 NVARCHAR(200) NULL,
        Criticality           NVARCHAR(30) NULL,
        ExistingTaskCount     INT NOT NULL,
        GapObligationsJson    NVARCHAR(MAX) NULL,
        OpenedDt              DATETIME2(3) NULL,
        ReopenedDt            DATETIME2(3) NULL
    );

    INSERT INTO @results
        (PracticeInstanceId, PracticeGapId, InstanceCode, InstanceName,
         PracticeId, PracticeCode, PracticeName,
         OrganizationId, OrganizationName,
         ImplementationStatus, GapObligationCount,
         Owner, Criticality, ExistingTaskCount,
         GapObligationsJson, OpenedDt, ReopenedDt)
    SELECT pi.practice_instance_id,
           pg.practice_gap_id,
           pi.instance_code,
           pi.instance_name,
           p.practice_id,
           p.practice_code,
           p.practice_name,
           o.organization_id,
           o.organization_name,
           -- Worst logged status among ACTIVE children.
           (SELECT CASE MIN(CASE pgo.logged_status_code
                                WHEN N'Not Implemented'       THEN 1
                                WHEN N'Partially Implemented' THEN 2
                                ELSE 3 END)
                       WHEN 1 THEN N'Not Implemented'
                       WHEN 2 THEN N'Partially Implemented'
                       ELSE N'Open'
                   END
             FROM  grac_practice.practice_gap_obligation pgo
             WHERE pgo.practice_gap_id = pg.practice_gap_id
               AND pgo.status          = N'Active'),
           (SELECT COUNT(*) FROM grac_practice.practice_gap_obligation pgo
             WHERE pgo.practice_gap_id = pg.practice_gap_id
               AND pgo.status          = N'Active'),
           pi.primary_owner,
           pi.criticality,
           (SELECT COUNT(*)
              FROM grac_practice.practice_task t
              JOIN grac_practice.task_type_master tt ON tt.task_type_id = t.task_type_id
             WHERE t.subject_entity_type = N'PracticeInstance'
               AND t.subject_entity_id   = pi.practice_instance_id
               AND tt.type_code          = N'Implementation'
               AND t.closed_at IS NULL),
           -- Snapshot of the obligations the gap actually logged.
           -- The name column here is the one recorded at the moment the
           -- obligation entered the gap, not whatever the current
           -- adoption row says.
           (SELECT pgo.practice_instance_obligation_id AS obligationId,
                   pgo.obligation_name                 AS name,
                   pgo.obligation_type_code            AS typeCode,
                   pgo.logged_status_code              AS status,
                   pgo.added_dt                        AS addedDt
            FROM   grac_practice.practice_gap_obligation pgo
            WHERE  pgo.practice_gap_id = pg.practice_gap_id
              AND  pgo.status          = N'Active'
            ORDER  BY CASE pgo.logged_status_code
                           WHEN N'Not Implemented'       THEN 1
                           WHEN N'Partially Implemented' THEN 2
                           ELSE 3 END,
                      pgo.obligation_name
            FOR JSON PATH),
           pg.opened_dt,
           pg.reopened_dt
    FROM   grac_practice.practice_gap pg
    JOIN   grac_practice.practice_instance pi
           ON pi.practice_instance_id = pg.practice_instance_id
    LEFT   JOIN grac_practice.practice p ON p.practice_id = pi.practice_id
    LEFT   JOIN grac_practice.organization o ON o.organization_id = pi.organization_id
    WHERE (@organization_id IS NULL OR pi.organization_id = @organization_id)
      AND  pg.gap_status = N'Open'
      AND (@search IS NULL
           OR pi.instance_code LIKE N'%' + @search + N'%'
           OR pi.instance_name LIKE N'%' + @search + N'%'
           OR p.practice_name  LIKE N'%' + @search + N'%');

    SELECT COUNT(*) AS TotalRows FROM @results;

    SELECT PracticeInstanceId, PracticeGapId, InstanceCode, InstanceName,
           PracticeId, PracticeCode, PracticeName,
           OrganizationId, OrganizationName,
           ImplementationStatus, GapObligationCount,
           Owner, Criticality, ExistingTaskCount,
           GapObligationsJson, OpenedDt, ReopenedDt
    FROM   @results
    ORDER  BY InstanceCode
    OFFSET (@page - 1) * @page_size ROWS
    FETCH NEXT @page_size ROWS ONLY;
END
GO
PRINT '245: sp_task_center_gaps_list now reads from practice_gap.';
GO

-- =====================================================================
-- Verification
-- =====================================================================
PRINT '=== 245 verification ===';

SELECT '245-a practice_gap present' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.practice_gap','U') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '245-b practice_gap_obligation present',
       CASE WHEN OBJECT_ID('grac_practice.practice_gap_obligation','U') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '245-c uniqueness: one gap per practice_instance_id',
       CASE WHEN EXISTS (SELECT 1 FROM sys.indexes
                          WHERE object_id = OBJECT_ID('grac_practice.practice_gap')
                            AND name      = 'uq_pm_practice_gap_instance'
                            AND is_unique = 1) THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '245-d filtered unique index for Active children',
       CASE WHEN EXISTS (SELECT 1 FROM sys.indexes
                          WHERE object_id = OBJECT_ID('grac_practice.practice_gap_obligation')
                            AND name      = 'uq_pm_practice_gap_obligation_active'
                            AND is_unique = 1
                            AND has_filter= 1) THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '245-e sync proc present',
       CASE WHEN OBJECT_ID('grac_practice.sp_practice_gap_sync_for_instance','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '245-f gaps_list reads from practice_gap',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_task_center_gaps_list','P'))
                 LIKE '%practice_gap%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '245-g gaps_list still carries GapObligationsJson',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_task_center_gaps_list','P'))
                 LIKE '%GapObligationsJson%'
            THEN 'PASS' ELSE 'FAIL' END;

PRINT '';
PRINT '=== Backfilled gaps ===';
SELECT pg.practice_gap_id, pg.practice_instance_id, pg.gap_status,
       (SELECT COUNT(*) FROM grac_practice.practice_gap_obligation pgo
         WHERE pgo.practice_gap_id = pg.practice_gap_id AND pgo.status = N'Active') AS ActiveChildren
FROM   grac_practice.practice_gap pg
ORDER  BY pg.practice_gap_id;

PRINT '';
PRINT '245 complete. Gaps are persistent; sync runs on every obligation save.';
GO

SET NOEXEC OFF;
GO
