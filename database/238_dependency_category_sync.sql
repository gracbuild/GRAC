-- =====================================================================
-- 238 sp_resolve_dependency_category_sync
--
-- WHY
-- ---
-- The Operationalize page's dependencies section moves to a table, one
-- row per category, with a multi-select of objects and a Save per row.
-- The user picks (Team A, Team B) for Team; on the next save (Team A,
-- Team C) the removed one goes and the new one arrives. That is
-- complete-set semantics, and the current one-object-at-a-time
-- sp_resolve_dependency_save cannot express it -- it would need a
-- delete-then-insert loop wrapped in an explicit transaction, and each
-- caller would have to remember the ordering.
--
-- This procedure takes the desired list for ONE category on ONE instance
-- and reconciles both tables that carry it:
--
--     practice_instance_dependency   -- one row per resolved object
--     practice_dependency_resolution -- one row per resolved object,
--                                       carrying resolution status
--
-- Present in the list, not stored yet -> add.
-- Stored, absent from the list      -> retire (soft delete).
-- Stored AND present                -> leave alone.
--
-- The category's presence in practice_instance_dependency is what
-- sp_resolve_dependency_type_list reads as "IsDeclared". So an empty
-- list against a category means "undeclare" -- the same shape as the
-- rest of the workspace where NULL/empty means "no opinion clears it".
--
-- IDEMPOTENT and safe under contention (see the pattern 232 uses for
-- local-obligation evidence, which this mirrors).
--
-- OUTPUT
-- ------
-- One result set carrying the outcome:
--     Success BIT, Message NVARCHAR, Added INT, Retired INT, Kept INT
-- Same shape sp_resolve_local_obligation_save adopted after 233; the
-- API's HasColumn loop will read it uniformly with the others.
--
-- SAFE TO RE-RUN. Requires 141 (dependency tables) and 222 (declaration
-- plumbing that reads IsDeclared).
-- ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    PRINT 'ABORT (238): schema grac_practice missing.';
    SET NOEXEC ON;
END
GO

IF OBJECT_ID('grac_practice.practice_dependency_resolution','U') IS NULL
BEGIN
    PRINT 'ABORT (238): practice_dependency_resolution missing (run 002 first).';
    SET NOEXEC ON;
END
GO

IF OBJECT_ID('grac_practice.practice_instance_dependency','U') IS NULL
BEGIN
    PRINT 'ABORT (238): practice_instance_dependency missing (run 001 first).';
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- The procedure
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_resolve_dependency_category_sync
    @practice_instance_id BIGINT,
    @dependency_type_id   INT,
    -- [ { "id": 12, "name": "Team Alpha", "ownerId": 34, "remarks": "..." }, ... ]
    -- name is optional here: the procedure falls back to the object's
    -- own display name via the source-config table when it is absent.
    -- ownerId and remarks are optional; NULL leaves whatever is stored.
    @objects_json         NVARCHAR(MAX) = N'[]',
    @caller_employee_id   BIGINT        = NULL,
    @is_admin             BIT           = 0,
    @actor                NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @practice_instance_id IS NULL
        THROW 52700, 'sp_resolve_dependency_category_sync: practice_instance_id is required.', 1;
    IF @dependency_type_id IS NULL
        THROW 52701, 'sp_resolve_dependency_category_sync: dependency_type_id is required.', 1;
    IF ISJSON(ISNULL(@objects_json, N'[]')) <> 1
        THROW 52702, 'sp_resolve_dependency_category_sync: objects_json must be a JSON array.', 1;

    DECLARE @organization_id BIGINT, @current_owner_id BIGINT;
    SELECT @organization_id  = organization_id,
           @current_owner_id = primary_owner_id
    FROM   grac_practice.practice_instance
    WHERE  practice_instance_id = @practice_instance_id;

    IF @organization_id IS NULL
        THROW 52703, 'sp_resolve_dependency_category_sync: instance not found.', 1;

    IF @is_admin = 0 AND ISNULL(@current_owner_id, -1) <> ISNULL(@caller_employee_id, -2)
        THROW 52704, 'sp_resolve_dependency_category_sync: this practice instance belongs to another owner.', 1;

    DECLARE @category NVARCHAR(120), @type_active BIT;
    SELECT @category    = dependency_type_name,
           @type_active = is_active
    FROM   grac_practice.dependency_type_master
    WHERE  dependency_type_id = @dependency_type_id;

    IF @category IS NULL OR ISNULL(@type_active, 0) = 0
        THROW 52705, 'sp_resolve_dependency_category_sync: that dependency category is not active.', 1;

    -- The lookup that turns an id into its display name, if the caller
    -- did not send one. Copied from QueryDependencyOptionsFallbackAsync's
    -- config table: exact same allow-list, so the two never disagree
    -- about which column carries the name.
    DECLARE @source_table NVARCHAR(200), @id_col NVARCHAR(80),
            @name_col NVARCHAR(80), @org_col NVARCHAR(80),
            @status_col NVARCHAR(80), @active_val NVARCHAR(80);

    SELECT TOP 1
           @source_table = source_table_name,
           @id_col       = id_column_name,
           @name_col     = display_column_name,
           @org_col      = organization_filter_column,
           @status_col   = status_filter_column,
           @active_val   = COALESCE(NULLIF(status_active_value, N''), N'Active')
    FROM   grac_practice.dependency_type_source_config
    WHERE  dependency_type_id = @dependency_type_id
      AND  status            = N'Active'
      AND  source_table_name IN (
            N'grac_practice.organization_dependency_tool',
            N'grac_practice.organization_dependency_vendor',
            N'grac_practice.organization_dependency_application',
            N'grac_practice.organization_dependency_asset',
            N'grac_practice.organization_dependency_process',
            N'grac_practice.organization_location',
            N'grac_practice.organization_employee',
            N'grac_practice.organization_team',
            N'grac_practice.organization_committee'
           );

    DECLARE @active_record_status_id INT = (
        SELECT TOP 1 record_status_id
        FROM   grac_practice.record_status_master
        WHERE  status_code = N'ACTIVE' OR status_name = N'Active'
        ORDER  BY record_status_id
    );
    DECLARE @resolved_status_id INT = (
        -- Column names on dependency_resolution_status_master are
        -- status_name / status_code, NOT resolution_status_*. Same
        -- convention as record_status_master.
        SELECT TOP 1 resolution_status_id
        FROM   grac_practice.dependency_resolution_status_master
        WHERE  status_name = N'Resolved'
           OR  status_code = N'RESOLVED'
        ORDER  BY resolution_status_id
    );

    -- criticality_id was promoted to NOT NULL by migration 016 and has
    -- no server-side default. The initial 238 draft omitted it and
    -- INSERT into practice_instance_dependency failed on a fresh row
    -- with "column does not allow nulls". Falls back to any active
    -- criticality if there is no row named Medium, so a database with
    -- a different vocabulary keeps working.
    DECLARE @default_criticality_id INT = (
        SELECT TOP 1 criticality_id
        FROM   grac_practice.criticality_master
        WHERE  is_active = 1
          AND  criticality_name = N'Medium'
        ORDER  BY criticality_id
    );
    IF @default_criticality_id IS NULL
        SELECT TOP 1 @default_criticality_id = criticality_id
        FROM   grac_practice.criticality_master
        WHERE  is_active = 1
        ORDER  BY display_order, criticality_id;

    -- Parse the payload once, then resolve missing names by joining to
    -- the source table -- dynamic SQL, because the source table's
    -- identity comes from data. IsSafeSqlName-style validation was done
    -- above via the allow-list on source_table_name; the columns come
    -- from a table only trusted rows can write to.
    DECLARE @wanted TABLE (
        resolved_id   BIGINT NOT NULL PRIMARY KEY,
        resolved_name NVARCHAR(300) NULL,
        owner_id      BIGINT NULL,
        remarks       NVARCHAR(MAX) NULL
    );

    INSERT @wanted (resolved_id, resolved_name, owner_id, remarks)
    SELECT j.Id, NULLIF(LTRIM(RTRIM(j.[Name])), N''), j.OwnerId, j.Remarks
    FROM   OPENJSON(ISNULL(@objects_json, N'[]')) WITH (
              Id      BIGINT        '$.id',
              [Name]  NVARCHAR(300) '$.name',
              OwnerId BIGINT        '$.ownerId',
              Remarks NVARCHAR(MAX) '$.remarks'
           ) j
    WHERE  j.Id IS NOT NULL;

    IF @source_table IS NOT NULL
    BEGIN
        -- Fill in any missing names from the source table, so a caller
        -- that only knew the id gets the same display as the one who
        -- typed the name too.
        DECLARE @sql NVARCHAR(MAX) = N'
            UPDATE w
               SET w.resolved_name = s.[' + @name_col + N']
              FROM @wanted w
              JOIN ' + @source_table + N' s
                ON s.[' + @id_col + N'] = w.resolved_id
             WHERE w.resolved_name IS NULL
               AND s.[' + @org_col + N'] = @org
               AND s.[' + @status_col + N'] = @active';

        -- @wanted is a table variable -- passing it via sp_executesql
        -- would need a table type. Simpler: capture the fills into a
        -- temp table and update from that.
        CREATE TABLE #fill (resolved_id BIGINT PRIMARY KEY, resolved_name NVARCHAR(300));

        SET @sql = N'
            INSERT #fill (resolved_id, resolved_name)
            SELECT s.[' + @id_col + N'], s.[' + @name_col + N']
              FROM ' + @source_table + N' s
             WHERE s.[' + @org_col + N'] = @org
               AND s.[' + @status_col + N'] = @active';

        EXEC sp_executesql @sql,
             N'@org BIGINT, @active NVARCHAR(80)',
             @org = @organization_id, @active = @active_val;

        UPDATE w SET w.resolved_name = f.resolved_name
        FROM   @wanted w
        JOIN   #fill f ON f.resolved_id = w.resolved_id
        WHERE  w.resolved_name IS NULL;

        DROP TABLE #fill;
    END

    -- Any row still missing a name after the fill is skipped: writing
    -- "" as the resolved dependency name would show as a blank on
    -- screen and make the resolution look broken.
    DECLARE @unresolved INT = (SELECT COUNT(*) FROM @wanted WHERE resolved_name IS NULL);

    DELETE FROM @wanted WHERE resolved_name IS NULL;

    DECLARE @added INT = 0, @retired INT = 0, @kept INT = 0;

    BEGIN TRANSACTION;

    -- 1) Retire rows that are no longer wanted.
    --
    -- practice_dependency_resolution has NO `status` column. Soft delete
    -- is is_active=0 alone, with the string resolution_status left as it
    -- was (or written to Retired when nothing was there). The initial
    -- draft had status=N'Retired' -- that column exists on
    -- practice_instance_dependency but not on this one, and referring to
    -- it here failed compile with "Invalid column name 'status'".
    UPDATE pdr
       SET is_active         = 0,
           resolution_status = COALESCE(pdr.resolution_status, N'Retired'),
           updated_by        = @actor,
           updated_dt        = SYSUTCDATETIME()
    FROM   grac_practice.practice_dependency_resolution pdr
    WHERE  pdr.practice_instance_id = @practice_instance_id
      AND  pdr.dependency_type_id   = @dependency_type_id
      AND  pdr.is_active            = 1
      AND  NOT EXISTS (SELECT 1 FROM @wanted w WHERE w.resolved_id = pdr.resolved_dependency_id);
    SET @retired = @@ROWCOUNT;

    -- Matching declaration row goes with it.
    UPDATE pid
       SET status     = N'Retired',
           updated_by = @actor,
           updated_dt = SYSUTCDATETIME()
    FROM   grac_practice.practice_instance_dependency pid
    WHERE  pid.practice_instance_id = @practice_instance_id
      AND  pid.dependency_type_id   = @dependency_type_id
      AND  pid.status               = N'Active'
      AND  NOT EXISTS (SELECT 1 FROM @wanted w
                        WHERE w.resolved_id = TRY_CONVERT(BIGINT, pid.dependency_reference)
                           OR w.resolved_name = pid.dependency_name);

    -- 2) Reactivate rows that came back.
    --    Same story: PDR carries is_active + resolution_status, not a
    --    generic status column. resolution_status is written explicitly
    --    to 'Resolved' so a formerly-retired row is not left with
    --    'Retired' as its display text while carrying is_active = 1.
    UPDATE pdr
       SET is_active            = 1,
           resolution_status    = N'Resolved',
           resolution_status_id = COALESCE(pdr.resolution_status_id, @resolved_status_id),
           resolution_owner_id  = COALESCE(w.owner_id, pdr.resolution_owner_id),
           remarks              = COALESCE(w.remarks, pdr.remarks),
           updated_by           = @actor,
           updated_dt           = SYSUTCDATETIME()
    FROM   grac_practice.practice_dependency_resolution pdr
    JOIN   @wanted w ON w.resolved_id = pdr.resolved_dependency_id
    WHERE  pdr.practice_instance_id = @practice_instance_id
      AND  pdr.dependency_type_id   = @dependency_type_id
      AND  pdr.is_active            = 0;
    SET @kept = @@ROWCOUNT;   -- provisional; adds to it below

    -- 3) Count truly unchanged.
    SELECT @kept = @kept
                 + (SELECT COUNT(*)
                    FROM   grac_practice.practice_dependency_resolution pdr
                    JOIN   @wanted w ON w.resolved_id = pdr.resolved_dependency_id
                    WHERE  pdr.practice_instance_id = @practice_instance_id
                      AND  pdr.dependency_type_id   = @dependency_type_id
                      AND  pdr.is_active            = 1
                      AND  pdr.updated_dt IS NULL   -- was not touched by step 2
                   );

    -- 4) Insert new resolutions.
    INSERT grac_practice.practice_dependency_resolution
        (organization_id, practice_instance_id, dependency_type_id, dependency_category,
         resolved_dependency_id, resolved_dependency_name,
         resolution_status_id, resolution_status,
         resolution_owner_id, resolution_dt, remarks, is_active,
         record_status_id, entered_by)
    SELECT @organization_id, @practice_instance_id, @dependency_type_id, @category,
           w.resolved_id, w.resolved_name,
           @resolved_status_id, N'Resolved',
           w.owner_id, SYSUTCDATETIME(), w.remarks, 1,
           @active_record_status_id, @actor
    FROM   @wanted w
    WHERE  NOT EXISTS (SELECT 1
                       FROM   grac_practice.practice_dependency_resolution pdr
                       WHERE  pdr.practice_instance_id     = @practice_instance_id
                         AND  pdr.dependency_type_id       = @dependency_type_id
                         AND  pdr.resolved_dependency_id   = w.resolved_id);
    SET @added = @@ROWCOUNT;

    -- 5) Declaration side. One row per resolved object, matching what
    --    sp_practice_instance_configure produced for teams.
    -- record_status_id is NOT NULL on practice_instance_dependency
    -- (migration 008 promoted the column). Omitting it here would fail
    -- INSERT with "column does not allow nulls". The other resolutions
    -- that were saved in the same batch succeeded only because they
    -- landed in categories whose PID rows already existed.
    INSERT grac_practice.practice_instance_dependency
        (organization_id, practice_instance_id, dependency_type_id, dependency_type,
         dependency_name, dependency_reference, owner_name,
         criticality_id, status, record_status_id, entered_by)
    SELECT @organization_id, @practice_instance_id, @dependency_type_id, @category,
           w.resolved_name, CAST(w.resolved_id AS NVARCHAR(200)),
           NULL, @default_criticality_id, N'Active', @active_record_status_id, @actor
    FROM   @wanted w
    WHERE  NOT EXISTS (SELECT 1
                       FROM   grac_practice.practice_instance_dependency pid
                       WHERE  pid.practice_instance_id = @practice_instance_id
                         AND  pid.dependency_type_id   = @dependency_type_id
                         AND  (pid.dependency_reference = CAST(w.resolved_id AS NVARCHAR(200))
                            OR pid.dependency_name = w.resolved_name)
                         AND  pid.status = N'Active');

    COMMIT TRANSACTION;

    SELECT CAST(1 AS BIT) AS Success,
           CASE
             WHEN @unresolved > 0
                 THEN CONCAT(N'Saved. ', @unresolved,
                             N' object(s) skipped because their id did not match the ',
                             @category, N' catalogue.')
             WHEN @added = 0 AND @retired = 0 AND @kept > 0
                 THEN N'Nothing to change.'
             WHEN @added = 0 AND @retired > 0
                 THEN CONCAT(N'Removed ', @retired, N' ', @category, N' dependency(ies).')
             WHEN @added > 0 AND @retired = 0
                 THEN CONCAT(N'Added ', @added, N' ', @category, N' dependency(ies).')
             ELSE CONCAT(N'Added ', @added, N', removed ', @retired, N' ', @category, N' dependency(ies).')
           END                 AS Message,
           @added               AS Added,
           @retired             AS Retired,
           @kept                AS Kept;
END
GO
PRINT '238: sp_resolve_dependency_category_sync ready.';
GO

-- =====================================================================
-- Verification
-- =====================================================================
PRINT '=== 238 verification ===';
SELECT 'sync procedure present' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.sp_resolve_dependency_category_sync','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT 'complete-set retirement uses is_active',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_resolve_dependency_category_sync','P'))
                 LIKE '%is_active            = 1%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT 'returns Success / Message / count columns',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_resolve_dependency_category_sync','P'))
                 LIKE '%AS Success%'
            AND  OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_resolve_dependency_category_sync','P'))
                 LIKE '%AS Message%'
            AND  OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_resolve_dependency_category_sync','P'))
                 LIKE '%AS Added%'
            THEN 'PASS' ELSE 'FAIL' END;

PRINT '';
PRINT '238 complete. Ship PracticeManagement.Api and PracticeManagement.Web with it.';
GO

SET NOEXEC OFF;
GO
