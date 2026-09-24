-- =====================================================================
-- 192 Practice Management data reset -- keep masters, clear everything else
--
-- Sir's ask (2026-08-15): a script that deletes everything in this module
-- except the master tables.
--
-- WHAT THIS DOES
--   Deletes ROWS only. No table, FK, index, view or procedure is dropped.
--   After this runs the schema is identical -- only the data is gone.
--
-- WHAT SURVIVES (the "keep list", resolved dynamically at run time)
--   1. Every grac_practice table whose name ends in _master
--      (45 today: record_status_master, frequency_master, menu_master,
--       criticality_master, implementation_status_master,
--       gap_lifecycle_state_master, sla_process_type_master, ...).
--   2. Global, non-tenant configuration/security tables that carry no
--      organization_id and are seeded by deployment/03_Insert_Master_Data.sql
--      or by their own migration:
--         reference_option            (001) global option_group/value catalog
--         security_role               (004)
--         security_permission         (004)
--         security_role_permission    (004)
--         rbac_rule                   (040) origin-aware permission matrix
--         entity_state_transition_rule(035) state-machine transition catalog
--         feature_flag                (041) org feature toggles, FK -> feature_flag_master
--
-- WHAT GETS CLEARED
--   Every other grac_practice table -- organization + its structure
--   (division/department/location/team/committee/employee/role), practices,
--   practice_instance and its children, tasks, gaps, assurance, events,
--   workflow, evidence, documents, risks, exceptions, SLA config, audit trails.
--
-- DELIBERATE EXCLUSION FROM THE KEEP LIST
--   event_definition is NOT kept, even though it reads like configuration.
--   It is organization-scoped (organization_id NOT NULL) and carries FKs to
--   grac_practice.workflow and grac_practice.workflow_stage (migration 066),
--   both of which are cleared here. Keeping it would leave orphan rows and
--   make the workflow DELETE fail on a FK violation.
--
-- OUT OF SCOPE
--   Schema GRAC_New (Control Management / Authority Portal) is never touched,
--   including GRAC_New.evidence_type_master. This script only ever writes to
--   grac_practice.
--
-- TWO SCOPES (@Scope, added later for the catalogue re-import)
--   'ALL'        the original behaviour described above -- clear the whole
--                module, keep only masters and global config/security.
--   'CATALOGUE'  clear ONLY the repository-subscription-and-below subtree:
--                subscription, applicability, org statements/controls/
--                requirements, practices, instances, and every table that
--                hangs off them (tasks, gaps, assurance, evidence, events,
--                risks, exceptions). Organisation, employees, roles,
--                departments, workflow definitions and masters SURVIVE.
--                Use this to reload the practice/obligation catalogue
--                without rebuilding the tenant from scratch.
--
--                Membership is not a hand-written table list. Section 2
--                seeds from @CatalogueRoots and then closes over foreign
--                keys, so every child of a root is included automatically
--                and a table added by a future migration needs no edit
--                here. Everything else in the engine below -- the blocker
--                pre-flight, FK levelling, cycle breaking, trigger
--                handling, verification and identity reseed -- is shared
--                by both scopes, unchanged.
--
-- SAFETY
--   * @DryRun = 1 by default -- prints the full plan (order + row counts) and
--     changes nothing. Set to 0 to execute.
--   * @Scope is validated below; an unrecognised value aborts.
--   * @ConfirmDatabase must be typed to match DB_NAME() before it will run
--     for real. Prevents a stray F5 against the wrong database.
--   * Pre-flight abort if any table OUTSIDE the delete set (a kept master, or
--     any table in another schema) has a FK pointing INTO the delete set.
--   * Delete order is derived from sys.foreign_keys at run time -- children
--     before parents -- so every FK stays enabled and checked throughout.
--     No NOCHECK, no constraint drop/recreate.
--   * Triggers on the tables being cleared are disabled for the duration of
--     the transaction and re-enabled before it commits. This is required,
--     not cosmetic: grac_practice.practice_audit_trace and
--     grac_practice.entity_state_transition_log each carry an
--     INSTEAD OF UPDATE, DELETE trigger that raises 51001 / 53501 to keep
--     the audit trails append-only, so a plain DELETE against them fails.
--     Only triggers that are currently ENABLED are touched, and each is
--     re-enabled by name, so a trigger an operator disabled on purpose
--     stays disabled. Trigger DDL is transactional -- if anything rolls
--     back, the triggers come back with it.
--   * The whole delete runs in one transaction. Any failure rolls back.
--
-- ROLLBACK
--   None. Deleted rows are gone. Restore from backup, then rerun
--   deployment/03_Insert_Master_Data.sql if masters also need reseeding.
--   Take a backup before running with @DryRun = 0.
--
-- Re-runnable: yes (second run finds nothing to delete).
-- Single batch on purpose -- the switches below are batch-scoped variables.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/* ------------------------------------------------------------------ */
/* OPERATOR SWITCHES -- edit these three lines only                    */
/* ------------------------------------------------------------------ */
DECLARE @DryRun          BIT     = 1;      -- 1 = plan only, 0 = delete for real
DECLARE @ConfirmDatabase SYSNAME = N'';    -- must equal DB_NAME() when @DryRun = 0
DECLARE @ReseedIdentity  BIT     = 1;      -- 1 = restart IDENTITY counters at 1
DECLARE @Scope           SYSNAME = N'ALL'; -- 'ALL' | 'CATALOGUE'  (see header)
/* ------------------------------------------------------------------ */

/* ------------------------------------------------------------------ */
/* CATALOGUE ROOTS -- only read when @Scope = 'CATALOGUE'.             */
/*                                                                     */
/* Name only the TOP of the subtree. Everything that references these  */
/* -- children, grandchildren, link tables -- is added automatically   */
/* by the foreign-key closure in section 2, so this list stays short   */
/* and does not need editing when a new child table appears.           */
/*                                                                     */
/* The default is "repository subscription, applicability, and         */
/* everything below": what an organisation SUBSCRIBED to and everything*/
/* derived from it. Organisation, employees, roles, departments,       */
/* workflow definitions and masters are parents of these, not          */
/* children, so they survive.                                          */
/*                                                                     */
/* Run with @DryRun = 1 first and read the printed table list. If a    */
/* table you expected is missing, add its root here; if one you wanted */
/* kept appears, remove the root that pulled it in.                    */
/* ------------------------------------------------------------------ */
DECLARE @CatalogueRoots TABLE (table_name SYSNAME NOT NULL PRIMARY KEY);
INSERT INTO @CatalogueRoots (table_name) VALUES
    (N'repository_subscription'),                -- the subscription itself
    (N'subscription_recommendation_history'),
    (N'organization_framework_statements'),      -- statements pulled from the release
    (N'organization_statement_applicability'),   -- applicability decisions
    (N'organization_control'),                   -- control context per org
    (N'organization_control_requirement'),
    (N'organization_requirement'),               -- requirements derived from statements
    (N'organization_statement_practice_mapping'),
    (N'custom_release_source_structure'),        -- org-authored releases
    (N'custom_release_statement'),
    (N'practice');                               -- practice + instance + everything below
/* ------------------------------------------------------------------ */

DECLARE @sql        NVARCHAR(MAX),
        @tbl        SYSNAME,
        @trg        SYSNAME,
        @objid      INT,
        @lvl        INT,
        @pass       INT = 0,
        @changed    INT = 1,
        @deleted    BIGINT,
        @totalRows  BIGINT = 0,
        @blockers   INT = 0,
        @cycles     INT = 0,
        @keepCount  INT = 0,
        @targetCount INT = 0;

/* Leftovers from a previous run in the same session (the dry-run path exits
   early via RETURN and never reaches the DROP TABLE block at the bottom). */
IF OBJECT_ID('tempdb..#keep')        IS NOT NULL DROP TABLE #keep;
IF OBJECT_ID('tempdb..#target')      IS NOT NULL DROP TABLE #target;
IF OBJECT_ID('tempdb..#blockers')    IS NOT NULL DROP TABLE #blockers;
IF OBJECT_ID('tempdb..#ignore_fk')   IS NOT NULL DROP TABLE #ignore_fk;
IF OBJECT_ID('tempdb..#trig')        IS NOT NULL DROP TABLE #trig;
IF OBJECT_ID('tempdb..#verify')      IS NOT NULL DROP TABLE #verify;
IF OBJECT_ID('tempdb..#kept_counts') IS NOT NULL DROP TABLE #kept_counts;

IF SCHEMA_ID('grac_practice') IS NULL
    THROW 51000, 'Schema grac_practice is missing. Run 001_practice_management_schema.sql first.', 1;

IF @Scope IS NULL OR @Scope NOT IN (N'ALL', N'CATALOGUE')
    THROW 51005, 'Set @Scope to N''ALL'' or N''CATALOGUE''.', 1;

IF @DryRun = 0 AND (@ConfirmDatabase IS NULL OR @ConfirmDatabase <> DB_NAME())
BEGIN
    PRINT '>>> BLOCKED. Set @ConfirmDatabase = N''' + DB_NAME() + ''' to run this for real.';
    THROW 51001, 'Database confirmation missing or does not match the current database.', 1;
END

PRINT '=====================================================================';
PRINT '192 Practice Management data reset';
PRINT '  Database : ' + DB_NAME();
PRINT '  Scope    : ' + @Scope
    + CASE WHEN @Scope = N'CATALOGUE'
           THEN ' (repository subscription and everything below it)'
           ELSE ' (whole module except masters and global config)' END;
PRINT '  Mode     : ' + CASE WHEN @DryRun = 1 THEN 'DRY RUN (nothing will be deleted)' ELSE 'EXECUTE' END;
PRINT '  Started  : ' + CONVERT(NVARCHAR(30), SYSUTCDATETIME(), 126) + 'Z';
PRINT '=====================================================================';

/* ------------------------------------------------------------------ */
/* 1. Keep list                                                        */
/* ------------------------------------------------------------------ */
CREATE TABLE #keep (table_name SYSNAME NOT NULL PRIMARY KEY, keep_reason NVARCHAR(60) NOT NULL);

IF @Scope = N'ALL'
BEGIN
    INSERT INTO #keep (table_name, keep_reason)
    SELECT t.name, N'master table'
    FROM sys.tables t
    JOIN sys.schemas s ON s.schema_id = t.schema_id
    WHERE s.name = 'grac_practice'
      AND t.name LIKE '%[_]master';

    INSERT INTO #keep (table_name, keep_reason)
    SELECT v.table_name, N'global config/security'
    FROM (VALUES
            (N'reference_option'),
            (N'security_role'),
            (N'security_permission'),
            (N'security_role_permission'),
            (N'rbac_rule'),
            (N'entity_state_transition_rule'),
            (N'feature_flag')
         ) AS v(table_name)
    WHERE EXISTS (SELECT 1 FROM sys.tables t
                  JOIN sys.schemas s ON s.schema_id = t.schema_id
                  WHERE s.name = 'grac_practice' AND t.name = v.table_name)
      AND NOT EXISTS (SELECT 1 FROM #keep k WHERE k.table_name = v.table_name);
END
/* In CATALOGUE scope the keep list is whatever the delete set does not
   claim, so it is filled in AFTER section 2. */

/* ------------------------------------------------------------------ */
/* 2. Delete set                                                       */
/* ------------------------------------------------------------------ */
CREATE TABLE #target
(
    object_id  INT      NOT NULL PRIMARY KEY,
    table_name SYSNAME  NOT NULL,
    lvl        INT      NULL,
    row_est    BIGINT   NULL,
    has_ident  BIT      NOT NULL DEFAULT 0
);

IF @Scope = N'ALL'
BEGIN
    INSERT INTO #target (object_id, table_name, row_est, has_ident)
    SELECT t.object_id,
           t.name,
           ISNULL((SELECT SUM(ps.row_count)
                   FROM sys.dm_db_partition_stats ps
                   WHERE ps.object_id = t.object_id AND ps.index_id IN (0, 1)), 0),
           CASE WHEN EXISTS (SELECT 1 FROM sys.identity_columns ic
                             WHERE ic.object_id = t.object_id) THEN 1 ELSE 0 END
    FROM sys.tables t
    JOIN sys.schemas s ON s.schema_id = t.schema_id
    WHERE s.name = 'grac_practice'
      AND t.is_ms_shipped = 0
      AND NOT EXISTS (SELECT 1 FROM #keep k WHERE k.table_name = t.name);
END
ELSE
BEGIN
    /* ---------------------------------------------------------------- */
    /* CATALOGUE scope: the subscription-and-below subtree only.        */
    /*                                                                  */
    /* Seeded with the roots listed in @CatalogueRoots, then CLOSED     */
    /* over foreign keys: any table that references something already   */
    /* in the set joins the set, repeatedly, until nothing new is       */
    /* found. That is what makes this safe to state as a short root     */
    /* list -- every child, grandchild and cross-link of a root is      */
    /* pulled in automatically, so a table added by a future migration  */
    /* is included the day it is created without editing this script.   */
    /*                                                                  */
    /* Everything the roots hang FROM stays: organization and its       */
    /* structure, employees, roles, departments, workflow definitions,  */
    /* masters. They are parents, never children, so the closure never  */
    /* reaches them.                                                    */
    /* ---------------------------------------------------------------- */
    INSERT INTO #target (object_id, table_name, row_est, has_ident)
    SELECT t.object_id, t.name, 0, 0
    FROM sys.tables t
    JOIN sys.schemas s ON s.schema_id = t.schema_id
    JOIN @CatalogueRoots r ON r.table_name = t.name
    WHERE s.name = 'grac_practice'
      AND t.is_ms_shipped = 0;

    IF NOT EXISTS (SELECT 1 FROM #target)
        THROW 51003, 'CATALOGUE scope: none of the root tables exist in this database. Check @CatalogueRoots.', 1;

    /* Report roots that were named but do not exist -- a typo in the
       root list would otherwise silently shrink the delete set. */
    IF EXISTS (SELECT 1 FROM @CatalogueRoots r
                WHERE NOT EXISTS (SELECT 1 FROM #target g WHERE g.table_name = r.table_name))
    BEGIN
        PRINT '>>> These named roots do not exist in grac_practice and were ignored:';
        SELECT r.table_name AS missing_root
        FROM @CatalogueRoots r
        WHERE NOT EXISTS (SELECT 1 FROM #target g WHERE g.table_name = r.table_name);
    END

    SET @changed = 1;
    SET @pass    = 0;
    WHILE @changed > 0 AND @pass < 100
    BEGIN
        INSERT INTO #target (object_id, table_name, row_est, has_ident)
        SELECT DISTINCT ct.object_id, ct.name, 0, 0
        FROM sys.foreign_keys fk
        JOIN sys.tables  ct ON ct.object_id = fk.parent_object_id
        JOIN sys.schemas cs ON cs.schema_id = ct.schema_id
        WHERE cs.name = 'grac_practice'
          AND ct.is_ms_shipped = 0
          AND fk.referenced_object_id IN (SELECT object_id FROM #target)
          AND fk.parent_object_id NOT IN (SELECT object_id FROM #target);

        SET @changed = @@ROWCOUNT;
        SET @pass += 1;
    END

    /* Row estimates and identity flags, once the membership is settled. */
    UPDATE g
       SET g.row_est   = ISNULL((SELECT SUM(ps.row_count)
                                 FROM sys.dm_db_partition_stats ps
                                 WHERE ps.object_id = g.object_id AND ps.index_id IN (0, 1)), 0),
           g.has_ident = CASE WHEN EXISTS (SELECT 1 FROM sys.identity_columns ic
                                           WHERE ic.object_id = g.object_id) THEN 1 ELSE 0 END
    FROM #target g;

    /* A master table reached by the closure is a modelling surprise, not
       a routine event: masters are supposed to be parents. Say so rather
       than quietly wiping a seeded catalog. */
    IF EXISTS (SELECT 1 FROM #target WHERE table_name LIKE '%[_]master')
    BEGIN
        PRINT '>>> BLOCKED. The closure reached one or more _master tables:';
        SELECT table_name FROM #target WHERE table_name LIKE '%[_]master' ORDER BY table_name;
        PRINT '    A master should never be a child of the catalogue subtree. Either the';
        PRINT '    root list is too wide, or that master carries an unexpected FK.';
        THROW 51004, 'CATALOGUE scope reached a master table. Nothing was deleted.', 1;
    END

    INSERT INTO #keep (table_name, keep_reason)
    SELECT t.name, N'outside catalogue scope'
    FROM sys.tables t
    JOIN sys.schemas s ON s.schema_id = t.schema_id
    WHERE s.name = 'grac_practice'
      AND t.is_ms_shipped = 0
      AND NOT EXISTS (SELECT 1 FROM #target g WHERE g.object_id = t.object_id);
END

SELECT @totalRows = SUM(row_est) FROM #target;
SELECT @keepCount = COUNT(*) FROM #keep;
SELECT @targetCount = COUNT(*) FROM #target;

/* PRINT takes a scalar expression only -- subqueries are illegal here,
   hence the counts are read into variables first. */
PRINT 'Tables kept    : ' + CAST(@keepCount AS NVARCHAR(10));
PRINT 'Tables to clear: ' + CAST(@targetCount AS NVARCHAR(10))
    + '  (approx ' + CAST(ISNULL(@totalRows, 0) AS NVARCHAR(20)) + ' rows)';
PRINT '';

/* ------------------------------------------------------------------ */
/* 3. Pre-flight: anything outside the delete set pointing into it?     */
/*    (a kept master, or a table in another schema)                     */
/* ------------------------------------------------------------------ */
SELECT fk.name                                              AS fk_name,
       QUOTENAME(cs.name) + '.' + QUOTENAME(ct.name)        AS referencing_table,
       QUOTENAME(rs.name) + '.' + QUOTENAME(rt.name)        AS referenced_table
INTO #blockers
FROM sys.foreign_keys fk
JOIN sys.tables  ct ON ct.object_id  = fk.parent_object_id
JOIN sys.schemas cs ON cs.schema_id  = ct.schema_id
JOIN sys.tables  rt ON rt.object_id  = fk.referenced_object_id
JOIN sys.schemas rs ON rs.schema_id  = rt.schema_id
WHERE fk.referenced_object_id IN (SELECT object_id FROM #target)
  AND fk.parent_object_id NOT IN (SELECT object_id FROM #target);

SELECT @blockers = COUNT(*) FROM #blockers;

IF @blockers > 0
BEGIN
    PRINT '>>> BLOCKERS: these tables are NOT being cleared but reference tables that are.';
    PRINT '    Either add the referencing table to the delete set, or add the referenced';
    PRINT '    table to the keep list, then rerun.';
    SELECT fk_name, referencing_table, referenced_table FROM #blockers ORDER BY referencing_table;
    THROW 51002, 'Foreign keys from outside the delete set point into it. Nothing was deleted.', 1;
END

/* ------------------------------------------------------------------ */
/* 4. Delete order: children (level 0) first, parents last              */
/*                                                                      */
/*    This schema contains a genuine FK cycle (migration 069):          */
/*      org_assurance_definition.current_version_id -> ..._version      */
/*      org_assurance_definition.active_version_id  -> ..._version      */
/*      org_assurance_definition_version.org_assurance_definition_id    */
/*                                       -> org_assurance_definition    */
/*    No delete order can satisfy both directions, so the cycle is      */
/*    broken the same way the schema intended: the two nullable pointer  */
/*    columns on the parent side are set to NULL first, that FK is then  */
/*    ignored for ordering purposes, and the levelling is recomputed.    */
/*    Detection is generic -- any future nullable-column cycle is        */
/*    handled the same way, and a cycle over NOT NULL columns still      */
/*    aborts the script rather than guessing.                            */
/* ------------------------------------------------------------------ */
CREATE TABLE #ignore_fk
(
    constraint_object_id INT           NOT NULL PRIMARY KEY,
    fk_name              SYSNAME       NOT NULL,
    parent_table         SYSNAME       NOT NULL,
    referenced_table     SYSNAME       NOT NULL,
    null_stmt            NVARCHAR(MAX) NOT NULL
);

DECLARE @breakPass INT = 0, @broke INT = 0;

WHILE 1 = 1
BEGIN
    UPDATE #target SET lvl = NULL;
    SET @pass = 0;
    SET @changed = 1;

    /* Level 0 = nothing in the delete set references it. */
    UPDATE t
       SET t.lvl = 0
    FROM #target t
    WHERE NOT EXISTS (SELECT 1
                      FROM sys.foreign_keys fk
                      JOIN #target c ON c.object_id = fk.parent_object_id
                      WHERE fk.referenced_object_id = t.object_id
                        AND fk.parent_object_id <> fk.referenced_object_id
                        AND fk.object_id NOT IN (SELECT constraint_object_id FROM #ignore_fk));

    WHILE @changed > 0 AND @pass < 100
    BEGIN
        UPDATE t
           SET t.lvl = x.next_lvl
        FROM #target t
        CROSS APPLY (SELECT next_lvl = MAX(c.lvl) + 1
                     FROM sys.foreign_keys fk
                     JOIN #target c ON c.object_id = fk.parent_object_id
                     WHERE fk.referenced_object_id = t.object_id
                       AND fk.parent_object_id <> fk.referenced_object_id
                       AND fk.object_id NOT IN (SELECT constraint_object_id FROM #ignore_fk)) x
        WHERE t.lvl IS NULL
          AND x.next_lvl IS NOT NULL
          AND NOT EXISTS (SELECT 1
                          FROM sys.foreign_keys fk2
                          JOIN #target c2 ON c2.object_id = fk2.parent_object_id
                          WHERE fk2.referenced_object_id = t.object_id
                            AND fk2.parent_object_id <> fk2.referenced_object_id
                            AND fk2.object_id NOT IN (SELECT constraint_object_id FROM #ignore_fk)
                            AND c2.lvl IS NULL);

        SET @changed = @@ROWCOUNT;
        SET @pass += 1;
    END

    IF NOT EXISTS (SELECT 1 FROM #target WHERE lvl IS NULL) BREAK;   -- fully ordered
    IF @breakPass >= 10 BREAK;                                       -- safety valve

    /* Still stuck: park every all-nullable FK inside the unresolved
       group, NULL those columns at delete time, and re-level. */
    INSERT INTO #ignore_fk (constraint_object_id, fk_name, parent_table, referenced_table, null_stmt)
    SELECT fk.object_id,
           fk.name,
           pt.name,
           rt.name,
           N'UPDATE grac_practice.' + QUOTENAME(pt.name) + N' SET '
             + STUFF((SELECT N', ' + QUOTENAME(c.name) + N' = NULL'
                      FROM sys.foreign_key_columns fkc
                      JOIN sys.columns c ON c.object_id = fkc.parent_object_id
                                        AND c.column_id = fkc.parent_column_id
                      WHERE fkc.constraint_object_id = fk.object_id
                      ORDER BY fkc.constraint_column_id
                      FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, N'') + N';'
    FROM sys.foreign_keys fk
    JOIN sys.tables pt ON pt.object_id = fk.parent_object_id
    JOIN sys.tables rt ON rt.object_id = fk.referenced_object_id
    WHERE fk.parent_object_id     IN (SELECT object_id FROM #target WHERE lvl IS NULL)
      AND fk.referenced_object_id IN (SELECT object_id FROM #target WHERE lvl IS NULL)
      AND fk.parent_object_id <> fk.referenced_object_id
      AND fk.object_id NOT IN (SELECT constraint_object_id FROM #ignore_fk)
      AND NOT EXISTS (SELECT 1                                   -- every FK column must be nullable
                      FROM sys.foreign_key_columns fkc
                      JOIN sys.columns c ON c.object_id = fkc.parent_object_id
                                        AND c.column_id = fkc.parent_column_id
                      WHERE fkc.constraint_object_id = fk.object_id
                        AND c.is_nullable = 0);

    SET @broke = @@ROWCOUNT;
    IF @broke = 0 BREAK;                 -- cycle exists but cannot be broken safely
    SET @breakPass += 1;
END

SELECT @cycles = COUNT(*) FROM #target WHERE lvl IS NULL;

IF @cycles > 0
BEGIN
    PRINT '>>> Circular foreign keys that cannot be broken (NOT NULL columns on both sides):';
    SELECT table_name FROM #target WHERE lvl IS NULL ORDER BY table_name;
    THROW 51003, 'Unbreakable circular FK dependency in grac_practice. Nothing was deleted -- resolve manually.', 1;
END

IF EXISTS (SELECT 1 FROM #ignore_fk)
BEGIN
    PRINT 'Cycle-breaking pointer columns that will be set to NULL before the deletes:';
    SELECT fk_name,
           parent_table     = N'grac_practice.' + parent_table,
           referenced_table = N'grac_practice.' + referenced_table,
           null_stmt
    FROM #ignore_fk
    ORDER BY parent_table, fk_name;
END

/* ------------------------------------------------------------------ */
/* 4b. Triggers standing in the way                                     */
/*                                                                      */
/*     practice_audit_trace and entity_state_transition_log are         */
/*     append-only by design -- each has an INSTEAD OF UPDATE, DELETE   */
/*     trigger that throws rather than letting rows go. The AFTER       */
/*     INSERT/UPDATE triggers elsewhere (impl status sync, employee     */
/*     autoraise) do not fire on DELETE, but they are disabled too so   */
/*     that this script keeps working if one of them ever grows a       */
/*     DELETE branch.                                                   */
/* ------------------------------------------------------------------ */
CREATE TABLE #trig
(
    trigger_object_id INT     NOT NULL PRIMARY KEY,
    table_name        SYSNAME NOT NULL,
    trigger_name      SYSNAME NOT NULL,
    is_instead_of     BIT     NOT NULL
);

INSERT INTO #trig (trigger_object_id, table_name, trigger_name, is_instead_of)
SELECT tr.object_id, t.table_name, tr.name, tr.is_instead_of_trigger
FROM sys.triggers tr
JOIN #target t ON t.object_id = tr.parent_id
WHERE tr.is_disabled = 0
  AND tr.parent_class = 1;          -- object-level triggers only

/* ------------------------------------------------------------------ */
/* 5. The plan                                                         */
/* ------------------------------------------------------------------ */
IF EXISTS (SELECT 1 FROM #trig)
BEGIN
    PRINT 'Triggers that will be disabled for the duration of the transaction:';
    SELECT trigger_name,
           on_table = N'grac_practice.' + table_name,
           kind     = CASE WHEN is_instead_of = 1
                           THEN 'INSTEAD OF -- blocks the delete, must be disabled'
                           ELSE 'AFTER -- disabled as a precaution' END
    FROM #trig
    ORDER BY table_name, trigger_name;
END

PRINT 'Delete plan (level 0 = leaf child, deleted first):';
SELECT delete_step = ROW_NUMBER() OVER (ORDER BY lvl, table_name),
       fk_level    = lvl,
       table_name  = N'grac_practice.' + table_name,
       approx_rows = row_est,
       identity_reseed = CASE WHEN has_ident = 1 THEN 'yes' ELSE 'no' END
FROM #target
ORDER BY lvl, table_name;

SELECT keep_reason, table_name = N'grac_practice.' + table_name
FROM #keep
ORDER BY keep_reason, table_name;

IF @DryRun = 1
BEGIN
    PRINT '';
    PRINT 'DRY RUN complete. Nothing was deleted.';
    PRINT 'To execute: set @DryRun = 0 and @ConfirmDatabase = N''' + DB_NAME() + ''' at the top.';
    PRINT 'Take a database backup first -- this script has no rollback.';
    RETURN;
END

/* ------------------------------------------------------------------ */
/* 6. Execute                                                          */
/* ------------------------------------------------------------------ */
PRINT '';
PRINT 'Deleting...';

BEGIN TRAN;

/* 6a-0. Disable the triggers on the tables being cleared. Trigger DDL is
         transactional, so a rollback anywhere below restores them. */
IF EXISTS (SELECT 1 FROM #trig)
BEGIN
    DECLARE trg_off CURSOR LOCAL FAST_FORWARD FOR
        SELECT table_name, trigger_name FROM #trig ORDER BY table_name, trigger_name;

    OPEN trg_off;
    FETCH NEXT FROM trg_off INTO @tbl, @trg;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @sql = N'ALTER TABLE grac_practice.' + QUOTENAME(@tbl)
                 + N' DISABLE TRIGGER ' + QUOTENAME(@trg) + N';';
        EXEC sp_executesql @sql;
        PRINT '  [trigger off] ' + @trg + ' on grac_practice.' + @tbl;
        FETCH NEXT FROM trg_off INTO @tbl, @trg;
    END

    CLOSE trg_off;
    DEALLOCATE trg_off;
END

/* 6a. Break the FK cycles first -- these are nullable pointer columns, so
       clearing them destroys no information the deletes were not about to
       remove anyway. */
IF EXISTS (SELECT 1 FROM #ignore_fk)
BEGIN
    DECLARE brk_cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT parent_table, null_stmt FROM #ignore_fk ORDER BY parent_table, fk_name;

    OPEN brk_cur;
    FETCH NEXT FROM brk_cur INTO @tbl, @sql;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        EXEC sp_executesql @sql;
        PRINT '  [cycle] grac_practice.' + @tbl + ' -- pointer column(s) cleared on '
            + CAST(@@ROWCOUNT AS NVARCHAR(20)) + ' row(s)';
        FETCH NEXT FROM brk_cur INTO @tbl, @sql;
    END

    CLOSE brk_cur;
    DEALLOCATE brk_cur;
END

/* 6b. Deletes, children first. */
DECLARE del_cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT object_id, table_name, lvl
    FROM #target
    ORDER BY lvl, table_name;

OPEN del_cur;
FETCH NEXT FROM del_cur INTO @objid, @tbl, @lvl;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @sql = N'DELETE FROM grac_practice.' + QUOTENAME(@tbl) + N';';
    EXEC sp_executesql @sql;
    SET @deleted = @@ROWCOUNT;

    IF @deleted > 0
        PRINT '  [L' + CAST(@lvl AS NVARCHAR(3)) + '] grac_practice.' + @tbl
            + ' -- ' + CAST(@deleted AS NVARCHAR(20)) + ' row(s)';

    FETCH NEXT FROM del_cur INTO @objid, @tbl, @lvl;
END

CLOSE del_cur;
DEALLOCATE del_cur;

/* 6c. Put the triggers back before anything else. Done inside the same
       transaction so the tables are never left unguarded. */
IF EXISTS (SELECT 1 FROM #trig)
BEGIN
    DECLARE trg_on CURSOR LOCAL FAST_FORWARD FOR
        SELECT table_name, trigger_name FROM #trig ORDER BY table_name, trigger_name;

    OPEN trg_on;
    FETCH NEXT FROM trg_on INTO @tbl, @trg;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @sql = N'ALTER TABLE grac_practice.' + QUOTENAME(@tbl)
                 + N' ENABLE TRIGGER ' + QUOTENAME(@trg) + N';';
        EXEC sp_executesql @sql;
        PRINT '  [trigger on ] ' + @trg + ' on grac_practice.' + @tbl;
        FETCH NEXT FROM trg_on INTO @tbl, @trg;
    END

    CLOSE trg_on;
    DEALLOCATE trg_on;
END

/* Nothing may survive in the delete set -- verify before committing. */
DECLARE @leftover INT = 0;

CREATE TABLE #verify (table_name SYSNAME NOT NULL, remaining BIGINT NOT NULL);

DECLARE vfy_cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT table_name FROM #target ORDER BY table_name;

OPEN vfy_cur;
FETCH NEXT FROM vfy_cur INTO @tbl;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @sql = N'INSERT INTO #verify(table_name, remaining)
                 SELECT @t, COUNT_BIG(*) FROM grac_practice.' + QUOTENAME(@tbl) + N';';
    EXEC sp_executesql @sql, N'@t SYSNAME', @t = @tbl;
    FETCH NEXT FROM vfy_cur INTO @tbl;
END

CLOSE vfy_cur;
DEALLOCATE vfy_cur;

SELECT @leftover = COUNT(*) FROM #verify WHERE remaining > 0;

IF @leftover > 0
BEGIN
    PRINT '>>> Rows survived the delete. Rolling back.';
    SELECT table_name, remaining FROM #verify WHERE remaining > 0 ORDER BY table_name;
    ROLLBACK TRAN;
    THROW 51004, 'Data reset did not fully clear the delete set. Transaction rolled back.', 1;
END

COMMIT TRAN;
PRINT 'Committed.';

/* ------------------------------------------------------------------ */
/* 7. Identity reseed (after COMMIT -- DBCC CHECKIDENT is not           */
/*    reliably transactional, so it must not sit inside the tran)       */
/* ------------------------------------------------------------------ */
IF @ReseedIdentity = 1
BEGIN
    PRINT 'Reseeding IDENTITY counters...';

    DECLARE ident_cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT table_name FROM #target WHERE has_ident = 1 ORDER BY table_name;

    OPEN ident_cur;
    FETCH NEXT FROM ident_cur INTO @tbl;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @sql = N'DBCC CHECKIDENT (''grac_practice.' + @tbl + N''', RESEED, 0) WITH NO_INFOMSGS;';
        EXEC sp_executesql @sql;
        FETCH NEXT FROM ident_cur INTO @tbl;
    END

    CLOSE ident_cur;
    DEALLOCATE ident_cur;

    PRINT 'Identity counters restart at 1.';
END

/* ------------------------------------------------------------------ */
/* 8. Proof: masters still populated                                    */
/* ------------------------------------------------------------------ */
PRINT '';
PRINT 'Kept tables and their surviving row counts:';

CREATE TABLE #kept_counts (table_name SYSNAME NOT NULL, keep_reason NVARCHAR(60) NOT NULL, rows_kept BIGINT NOT NULL);

DECLARE keep_cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT table_name FROM #keep ORDER BY table_name;

OPEN keep_cur;
FETCH NEXT FROM keep_cur INTO @tbl;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @sql = N'INSERT INTO #kept_counts(table_name, keep_reason, rows_kept)
                 SELECT @t, (SELECT keep_reason FROM #keep WHERE table_name = @t), COUNT_BIG(*)
                 FROM grac_practice.' + QUOTENAME(@tbl) + N';';
    EXEC sp_executesql @sql, N'@t SYSNAME', @t = @tbl;
    FETCH NEXT FROM keep_cur INTO @tbl;
END

CLOSE keep_cur;
DEALLOCATE keep_cur;

SELECT keep_reason,
       table_name = N'grac_practice.' + table_name,
       rows_kept,
       flag = CASE WHEN rows_kept = 0 THEN 'EMPTY -- reseed via deployment/03_Insert_Master_Data.sql' ELSE '' END
FROM #kept_counts
ORDER BY keep_reason, table_name;

PRINT '';
PRINT '192 data reset finished at ' + CONVERT(NVARCHAR(30), SYSUTCDATETIME(), 126) + 'Z.';
PRINT 'Next: rerun deployment/03_Insert_Master_Data.sql if any kept table came back EMPTY,';
PRINT 'then recreate the organization through the UI (Organization > Setup).';

/* Belt and braces: nothing this script disabled may still be disabled. */
IF EXISTS (SELECT 1
           FROM sys.triggers tr
           JOIN #trig g ON g.trigger_object_id = tr.object_id
           WHERE tr.is_disabled = 1)
BEGIN
    PRINT '>>> WARNING: these triggers are still disabled. Re-enable them before use:';
    SELECT trigger_name, on_table = N'grac_practice.' + table_name
    FROM #trig g
    JOIN sys.triggers tr ON tr.object_id = g.trigger_object_id
    WHERE tr.is_disabled = 1;
END
ELSE IF EXISTS (SELECT 1 FROM #trig)
    PRINT 'All disabled triggers were re-enabled.';

DROP TABLE #verify;
DROP TABLE #kept_counts;
DROP TABLE #blockers;
DROP TABLE #trig;
DROP TABLE #ignore_fk;
DROP TABLE #target;
DROP TABLE #keep;
GO

-- =====================================================================
-- POST-RESET: re-seed the four lifecycle event definitions   (335)
--
-- WHY THIS IS HERE
-- ----------------
-- The header above explains why event_definition is deliberately NOT on
-- the keep list: it is organization-scoped and FKs to workflow /
-- workflow_stage, both of which this script clears, so keeping it would
-- leave orphans and fail the workflow DELETE.
--
-- That reasoning is sound. What was missing is the other half: nothing
-- put the rows back. PEOPLE_ONBOARDING, PEOPLE_OFFBOARDING,
-- ASSET_COMMISSIONING and ASSET_DECOMMISSIONING are not organizational
-- configuration -- they are the codes sp_event_raise_people_lifecycle
-- and sp_event_raise_asset_lifecycle HARD-CODE (migration 126 calls them
-- "a CONTRACT with 124"). Clearing them leaves Raise Event throwing
--
--     sp_event_instance_raise_scoped: event definition not found for
--     organization.                                        (67223)
--
-- for every surviving organization, with nothing on screen explaining
-- why. Under @Scope = 'CATALOGUE' that is exactly the state the module
-- is left in: the organizations survive, their events do not.
--
-- WHAT IT DOES
-- ------------
-- Calls migration 335's sp_event_definition_ensure_baseline for every
-- surviving active organization. That procedure is INSERT-ONLY, so on a
-- 'ALL' reset -- where organization itself is cleared -- there is nothing
-- to iterate and this does nothing at all.
--
-- GUARDED, so this script still runs unchanged against a database that
-- has not had 335 applied. There it prints what to do instead, rather
-- than failing the reset over a re-seed.
--
-- Rows land with entered_by = 'reset-192', so a post-reset seed is
-- distinguishable from 126's and from 335's own gap fill.
-- =====================================================================
IF OBJECT_ID('grac_practice.sp_event_definition_ensure_baseline','P') IS NULL
BEGIN
    PRINT '';
    PRINT '>>> NOTE: sp_event_definition_ensure_baseline is not present (migration 335 not applied).';
    PRINT '>>> The four lifecycle event definitions were cleared and have NOT been restored.';
    PRINT '>>> Raise Event will fail with 67223 until you run 335_event_definition_ensure_baseline.sql';
    PRINT '>>> (or re-run 126_event_scope_baseline_seed.sql).';
END
ELSE
BEGIN
    DECLARE @reseed_org BIGINT, @reseed_count INT = 0;

    DECLARE reseed_cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT organization_id FROM grac_practice.organization
        WHERE status = N'Active' ORDER BY organization_id;

    OPEN reseed_cur;
    FETCH NEXT FROM reseed_cur INTO @reseed_org;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        EXEC grac_practice.sp_event_definition_ensure_baseline
             @organization_id = @reseed_org, @actor = N'reset-192';
        SET @reseed_count = @reseed_count + 1;
        FETCH NEXT FROM reseed_cur INTO @reseed_org;
    END
    CLOSE reseed_cur;
    DEALLOCATE reseed_cur;

    PRINT '';
    PRINT '192: lifecycle event definitions re-seeded for '
        + CAST(@reseed_count AS VARCHAR(20)) + ' surviving active organization(s).';
END
GO
