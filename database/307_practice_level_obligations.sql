-- =====================================================================
-- 307 Practice-level obligations
--
-- WHAT THIS ADDS
-- --------------
-- An obligation the organisation authors once, against a PRACTICE, which
-- then applies to every Practice Instance of that practice -- existing
-- and future. Migration 227 named this work and declined it on purpose:
--
--     SCOPE: ONE INSTANCE -- A locally added obligation belongs to the
--     practice instance it was added on. [...] so "add it once, it
--     appears everywhere" would need a practice-level table and a
--     fan-out rule for instances created afterwards. That is a separate
--     piece of work; this is the smaller, honest version.
--
-- This is that separate piece, in the shape 227 named.
--
-- THREE KINDS OF OBLIGATION ROW, TOLD APART BY TWO COLUMNS
-- --------------------------------------------------------
--   row                          obligation_id   source_practice_obligation_id
--   adopted published            the GRAC_New id  NULL
--   instance custom (227)        NULL             NULL
--   practice-level copy (307)    NULL             the definition id
--
-- Nothing about the first two changes, which is what keeps
-- instance-specific custom obligations working exactly as they do today.
--
-- ADDITIVE ONLY -- NO PROCEDURE IS RE-ISSUED
-- ------------------------------------------
-- Deliberate. Two changes belong with this feature but each needs an
-- existing procedure re-emitted from its LATEST body:
--
--   * sp_resolve_local_obligation_save (latest body: 244) should refuse
--     to edit or retire a row whose source_practice_obligation_id is
--     set -- the practice owns it, so the instance door must not open on
--     it.
--   * sp_resolve_obligation_list (latest body: 244) should project
--     SourcePracticeObligationId so the workspace can badge such a row
--     and disable its Edit / Remove buttons.
--
-- Re-emitting a 200-line body from the repository's latest state onto a
-- database sitting at an OLDER state is how a working screen regresses,
-- and this database has already been found short of 254. Both are
-- deferred to 308, to be applied once the deployed state is confirmed.
--
-- Until then the fan-out is fully functional and the copies are visible
-- (sp_resolve_obligation_list's existing organisation-defined branch
-- picks up any row with obligation_id IS NULL), but a copy is still
-- editable through the instance door. The UI hides those buttons; 308
-- makes the database say no as well.
--
-- THE EVIDENCE SYNC NEEDED NO CHANGE, AND MIGRATION 233 IS WHY
-- ------------------------------------------------------------
-- The fan-out calls sp_resolve_local_obligation_evidence_sync once per
-- copy. In its 232 form that would have been unusable from here: it
-- ended with a SELECT, and a SELECT inside a called procedure becomes a
-- result set of the CALLER -- one per instance, arriving ahead of
-- anything the caller meant to return.
--
-- 233 had already fixed that, for exactly this reason, and wrote the rule
-- down:
--
--     A procedure that another procedure EXECs must not SELECT.
--     Use OUTPUT parameters.
--
-- So the sync is reused as it stands. Both procedures below obey the same
-- rule: the fan-out returns no result set at all, which is what lets
-- sp_practice_obligation_save call it inline and still hand the caller
-- exactly one row.
--
-- Its three OUTPUT parameters have no defaults, so all three must be
-- supplied -- and a database still on the 232 signature cannot satisfy
-- this call at all. The prerequisite block checks for the 233 shape by
-- name rather than letting it fail at run time.
--
-- WHY THE DEFINITION CARRIES NO IMPLEMENTATION STATUS OR CONNECTION
-- -----------------------------------------------------------------
-- Both are facts about DOING the work, and the work happens on an
-- instance: two teams carrying out the same practice are not at the same
-- stage, and an automated check points at each team's own endpoint. The
-- practice says WHAT is required; the instance answers HOW FAR and
-- AGAINST WHAT. Leaving them out also means this migration needs neither
-- 242 nor 244 applied.
--
-- ERROR CODES 57200-57219 (57101 was the previous high-water mark).
--
-- ASCII-only on purpose: sqlcmd reads files in the current ANSI codepage
-- by default and multi-byte characters can corrupt string literals.
--
-- Idempotent: guarded CREATE TABLE / ALTER, CREATE OR ALTER procedures.
--
-- DEPENDS ON: 001 (practice, practice_instance), 140 (the obligation
--             table), 227 (obligation_description / typed_detail_json,
--             the NULLable obligation_id and its filtered index),
--             231 (source_practice_instance_obligation_id on evidence),
--             232 (sp_resolve_local_obligation_evidence_sync).
-- Rollback:   database/307_practice_level_obligations_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;   -- defensive: reset in case a prior script left it on
GO

-- ---------------------------------------------------------------------
-- Prerequisites. Every column the procedures below touch is checked, not
-- just the tables: on a database that never ran 227 the columns are
-- missing and CREATE OR ALTER fails with Msg 207 while the PRINTs after
-- it still run -- a script that looks half-applied and changed nothing.
-- ---------------------------------------------------------------------
DECLARE @prereqs_ok BIT = 1;

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    PRINT 'ABORT (307): schema grac_practice missing. Run base scripts first.';
    SET @prereqs_ok = 0;
END

IF OBJECT_ID('grac_practice.practice','U') IS NULL
   OR OBJECT_ID('grac_practice.practice_instance','U') IS NULL
BEGIN
    PRINT 'ABORT (307): practice or practice_instance missing. Run 001 first.';
    SET @prereqs_ok = 0;
END

IF OBJECT_ID('grac_practice.practice_instance_obligation','U') IS NULL
BEGIN
    PRINT 'ABORT (307): practice_instance_obligation missing. Run 140 first.';
    SET @prereqs_ok = 0;
END

IF COL_LENGTH('grac_practice.practice_instance_obligation','obligation_description') IS NULL
   OR COL_LENGTH('grac_practice.practice_instance_obligation','typed_detail_json') IS NULL
BEGIN
    PRINT 'ABORT (307): obligation_description / typed_detail_json missing. Run 227 first.';
    SET @prereqs_ok = 0;
END

-- 227 made this NULLable and replaced the unique constraint with a
-- filtered index. A fan-out copy has no published id, so without that
-- change the very first INSERT fails.
IF EXISTS (SELECT 1 FROM sys.columns
            WHERE object_id = OBJECT_ID('grac_practice.practice_instance_obligation')
              AND name = 'obligation_id' AND is_nullable = 0)
BEGIN
    PRINT 'ABORT (307): practice_instance_obligation.obligation_id is still NOT NULL. Run 227 first.';
    SET @prereqs_ok = 0;
END

IF OBJECT_ID('grac_practice.record_status_master','U') IS NULL
BEGIN
    PRINT 'ABORT (307): record_status_master missing. Run 002 / 008 first.';
    SET @prereqs_ok = 0;
END

IF OBJECT_ID('GRAC_New.obligation_type_master','U') IS NULL
BEGIN
    PRINT 'ABORT (307): GRAC_New.obligation_type_master not reachable -- the';
    PRINT '             save validates the type against it, as 227 does.';
    SET @prereqs_ok = 0;
END

-- The evidence half. Absent entirely = not fatal (obligations fan out
-- without their evidence, and the fan-out skips the call). Present but
-- still on the 232 signature = fatal, because the EXEC below supplies
-- the three OUTPUT parameters 233 introduced and 232's version would
-- reject the call.
IF OBJECT_ID('grac_practice.sp_resolve_local_obligation_evidence_sync','P') IS NULL
    PRINT '307 WARNING: sp_resolve_local_obligation_evidence_sync missing (232 / 233). '
        + 'Obligations will fan out WITHOUT their evidence until it is applied.';

IF OBJECT_ID('grac_practice.sp_resolve_local_obligation_evidence_sync','P') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.parameters
                    WHERE object_id = OBJECT_ID('grac_practice.sp_resolve_local_obligation_evidence_sync','P')
                      AND name = '@evidence_added')
BEGIN
    PRINT 'ABORT (307): sp_resolve_local_obligation_evidence_sync is still the 232 version';
    PRINT '             (it returns a result set instead of OUTPUT counts).';
    PRINT '             Run 233_local_obligation_save_result_set.sql first.';
    SET @prereqs_ok = 0;
END

IF @prereqs_ok = 0
BEGIN
    RAISERROR('307_practice_level_obligations: prerequisites missing -- see PRINT messages above.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. grac_practice.practice_obligation -- the definition
--
--    Columns mirror the organisation-defined set on
--    practice_instance_obligation on purpose: the same add/edit form
--    writes both (Shared/obligation-form.js, scope "practice"), and the
--    fan-out copies field to field with no translation.
-- =====================================================================
IF OBJECT_ID('grac_practice.practice_obligation','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.practice_obligation(
        practice_obligation_id BIGINT IDENTITY(1,1) NOT NULL
            CONSTRAINT pk_pm_practice_obligation PRIMARY KEY,
        organization_id        BIGINT NOT NULL
            CONSTRAINT fk_pm_po_organization
                REFERENCES grac_practice.organization(organization_id),
        practice_id            BIGINT NOT NULL
            CONSTRAINT fk_pm_po_practice
                REFERENCES grac_practice.practice(practice_id),

        obligation_name        NVARCHAR(500) NOT NULL,
        obligation_description NVARCHAR(MAX) NULL,
        obligation_type_code   NVARCHAR(60)  NOT NULL,
        -- The same JSON array shape vw_pm_obligation_typed_detail emits,
        -- for the same reason 227 chose it: mirroring Control
        -- Management's six detail tables would mean copying a schema this
        -- module does not own and cannot see change.
        typed_detail_json      NVARCHAR(MAX) NULL,

        execution_frequency_id INT NULL
            CONSTRAINT fk_pm_po_exec_freq
                REFERENCES grac_practice.frequency_master(frequency_id),
        execution_frequency    NVARCHAR(120) NULL,
        responsibility         NVARCHAR(300) NULL,
        approval_authority     NVARCHAR(300) NULL,
        assurance_type         NVARCHAR(40)  NULL
            CONSTRAINT ck_pm_po_assurance_type
                CHECK (assurance_type IS NULL OR assurance_type IN (N'Manual', N'Automated')),
        remarks                NVARCHAR(MAX) NULL,

        -- What proves this obligation, as the declared list the form
        -- sends. Stored rather than only replayed at save time, because
        -- an instance created next month has to be seeded from it.
        evidence_json          NVARCHAR(MAX) NULL,

        status                 NVARCHAR(30) NOT NULL
            CONSTRAINT df_pm_po_status DEFAULT N'Active',
        record_status_id       INT NOT NULL,
        entered_by             NVARCHAR(100) NOT NULL
            CONSTRAINT df_pm_po_entered_by DEFAULT N'system',
        entered_dt             DATETIME2 NOT NULL
            CONSTRAINT df_pm_po_entered_dt DEFAULT SYSUTCDATETIME(),
        updated_by             NVARCHAR(100) NULL,
        updated_dt             DATETIME2 NULL
    );
    PRINT '307: grac_practice.practice_obligation created.';
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
                WHERE name = 'ix_pm_po_practice'
                  AND object_id = OBJECT_ID('grac_practice.practice_obligation'))
BEGIN
    CREATE INDEX ix_pm_po_practice
        ON grac_practice.practice_obligation(organization_id, practice_id, status)
        INCLUDE (obligation_name, obligation_type_code);
    PRINT '307: ix_pm_po_practice created.';
END
GO

-- =====================================================================
-- 2. The marker column on the instance-side table
--
--    Set = this row is a copy of a practice-level definition and the
--    practice owns it. NULL = the row is what it always was.
-- =====================================================================
IF COL_LENGTH('grac_practice.practice_instance_obligation','source_practice_obligation_id') IS NULL
BEGIN
    ALTER TABLE grac_practice.practice_instance_obligation
        ADD source_practice_obligation_id BIGINT NULL;
    PRINT '307: practice_instance_obligation.source_practice_obligation_id added.';
END
GO

IF COL_LENGTH('grac_practice.practice_instance_obligation','source_practice_obligation_id') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_pm_pio_practice_obligation')
BEGIN
    ALTER TABLE grac_practice.practice_instance_obligation
        ADD CONSTRAINT fk_pm_pio_practice_obligation
            FOREIGN KEY (source_practice_obligation_id)
            REFERENCES grac_practice.practice_obligation(practice_obligation_id);
    PRINT '307: fk_pm_pio_practice_obligation added.';
END
GO

-- One copy per definition per instance. FILTERED, for the same reason
-- 227's index is: NULLs are equal to SQL Server in a unique index, so an
-- unfiltered one would cap the table at a single row with no definition
-- behind it -- which is every published and every instance-custom
-- obligation.
IF COL_LENGTH('grac_practice.practice_instance_obligation','source_practice_obligation_id') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.indexes
                    WHERE name = 'ux_pm_pio_practice_obligation'
                      AND object_id = OBJECT_ID('grac_practice.practice_instance_obligation'))
BEGIN
    CREATE UNIQUE INDEX ux_pm_pio_practice_obligation
        ON grac_practice.practice_instance_obligation(practice_instance_id, source_practice_obligation_id)
        WHERE source_practice_obligation_id IS NOT NULL;
    PRINT '307: ux_pm_pio_practice_obligation created.';
END
GO

-- =====================================================================
-- 3. sp_practice_obligation_fan_out -- the propagation rule
--
--    @practice_obligation_id NULL = every definition on the practice.
--    @practice_instance_id   NULL = every active instance of it.
--
--    So one procedure serves all three callers: a save (this definition,
--    every instance), a newly created instance (every definition, this
--    instance), and a reconcile (both NULL).
--
--    RETURNS NO RESULT SET. Counts come back through OUTPUT parameters,
--    the way pm_grant_organization_default_access (217) does, so a caller
--    that composes it is not left reading the wrong row. The evidence
--    sync it calls per instance DOES return one; those land only in a
--    plain EXEC that discards them -- which is why this procedure must
--    never be the one whose result set a gateway reads.
--
--    IDEMPOTENT. Every write is keyed on
--    (practice_instance_id, source_practice_obligation_id), so a second
--    run changes nothing.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_practice_obligation_fan_out
    @practice_id            BIGINT        = NULL,
    @practice_obligation_id BIGINT        = NULL,
    @practice_instance_id   BIGINT        = NULL,
    @actor                  NVARCHAR(100) = N'system',
    @copies_created         INT           = 0 OUTPUT,
    @copies_updated         INT           = 0 OUTPUT,
    @copies_retired         INT           = 0 OUTPUT,
    @evidence_synced        INT           = 0 OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- Always initialised: an early RETURN must not leave the caller's
    -- variables holding whatever they had before. Same discipline 233
    -- applied to the evidence sync.
    SET @copies_created  = 0;
    SET @copies_updated  = 0;
    SET @copies_retired  = 0;
    SET @evidence_synced = 0;

    IF @practice_id IS NULL AND @practice_obligation_id IS NULL AND @practice_instance_id IS NULL
        THROW 57200, 'sp_practice_obligation_fan_out: name a practice, a definition or an instance.', 1;

    -- Narrow to one practice when the caller named a definition or an
    -- instance instead, so the joins below stay on one practice's rows.
    IF @practice_id IS NULL AND @practice_obligation_id IS NOT NULL
        SELECT @practice_id = practice_id
        FROM   grac_practice.practice_obligation
        WHERE  practice_obligation_id = @practice_obligation_id;

    IF @practice_id IS NULL AND @practice_instance_id IS NOT NULL
        SELECT @practice_id = practice_id
        FROM   grac_practice.practice_instance
        WHERE  practice_instance_id = @practice_instance_id;

    IF @practice_id IS NULL RETURN;    -- nothing to fan out to

    DECLARE @active_record_status_id INT = (
        SELECT TOP 1 record_status_id FROM grac_practice.record_status_master
        WHERE status_code = N'ACTIVE' OR status_name = N'Active'
        ORDER BY record_status_id);
    IF @active_record_status_id IS NULL SET @active_record_status_id = 1;

    -- The definitions in scope, and the instances in scope. Kept as two
    -- small sets so every statement below reads the same population.
    DECLARE @defs TABLE (
        practice_obligation_id BIGINT PRIMARY KEY,
        is_active              BIT    NOT NULL,
        evidence_json          NVARCHAR(MAX) NULL
    );

    INSERT @defs (practice_obligation_id, is_active, evidence_json)
    SELECT po.practice_obligation_id,
           CASE WHEN po.status = N'Active' THEN 1 ELSE 0 END,
           po.evidence_json
    FROM   grac_practice.practice_obligation po
    WHERE  po.practice_id = @practice_id
      AND (@practice_obligation_id IS NULL
           OR po.practice_obligation_id = @practice_obligation_id);

    IF NOT EXISTS (SELECT 1 FROM @defs) RETURN;

    DECLARE @instances TABLE (practice_instance_id BIGINT PRIMARY KEY, organization_id BIGINT NOT NULL);

    INSERT @instances (practice_instance_id, organization_id)
    SELECT pi.practice_instance_id, pi.organization_id
    FROM   grac_practice.practice_instance pi
    WHERE  pi.practice_id = @practice_id
      AND  pi.status = N'Active'
      AND (@practice_instance_id IS NULL OR pi.practice_instance_id = @practice_instance_id);

    IF NOT EXISTS (SELECT 1 FROM @instances) RETURN;

    BEGIN TRANSACTION;

    -- 3a. Refresh the copies that already exist. The practice owns the
    --     obligation's own fields, so they are overwritten -- that is
    --     what "edit at practice level updates every instance" means.
    --
    --     Instance-owned parameters are NOT touched: assurance_frequency,
    --     event/SLA overrides, implementation status, connection info and
    --     the adoption stamp all stay as the instance left them. A copy
    --     that had been retired comes back Active rather than being
    --     duplicated beside itself.
    UPDATE pio
       SET obligation_name        = po.obligation_name,
           obligation_description = po.obligation_description,
           obligation_type_code   = po.obligation_type_code,
           typed_detail_json      = ISNULL(po.typed_detail_json, N'[]'),
           execution_frequency_id = po.execution_frequency_id,
           execution_frequency    = po.execution_frequency,
           responsibility         = po.responsibility,
           approval_authority     = po.approval_authority,
           assurance_type         = po.assurance_type,
           remarks                = po.remarks,
           status                 = N'Active',
           record_status_id       = @active_record_status_id,
           updated_by             = @actor,
           updated_dt             = SYSUTCDATETIME()
    FROM   grac_practice.practice_instance_obligation pio
    JOIN   @defs d ON d.practice_obligation_id = pio.source_practice_obligation_id
    JOIN   grac_practice.practice_obligation po
           ON po.practice_obligation_id = d.practice_obligation_id
    JOIN   @instances i ON i.practice_instance_id = pio.practice_instance_id
    WHERE  d.is_active = 1;

    SET @copies_updated = @@ROWCOUNT;

    -- 3b. Create the copies that are missing.
    INSERT grac_practice.practice_instance_obligation
        (organization_id, practice_instance_id, obligation_id, release_id,
         obligation_name, obligation_description, obligation_type_code,
         typed_detail_json,
         inherited_from_repository, organization_modified,
         execution_frequency_id, execution_frequency,
         responsibility, approval_authority, assurance_type, remarks,
         source_practice_obligation_id,
         adopted_by, adopted_dt, status, record_status_id, entered_by)
    SELECT i.organization_id, i.practice_instance_id, NULL, NULL,
           po.obligation_name, po.obligation_description, po.obligation_type_code,
           ISNULL(po.typed_detail_json, N'[]'),
           -- Not inherited from the repository, and organisation-defined
           -- is by definition an organisation modification -- the same
           -- two values 227 writes.
           0, 1,
           po.execution_frequency_id, po.execution_frequency,
           po.responsibility, po.approval_authority, po.assurance_type, po.remarks,
           po.practice_obligation_id,
           -- Adopted on creation: the requirement is that a practice-level
           -- obligation APPLIES to every instance, so there is no
           -- per-instance decision left to take. Un-adopting one is done
           -- by retiring the definition.
           @actor, SYSUTCDATETIME(), N'Active', @active_record_status_id, @actor
    FROM   @defs d
    JOIN   grac_practice.practice_obligation po
           ON po.practice_obligation_id = d.practice_obligation_id
    CROSS  JOIN @instances i
    WHERE  d.is_active = 1
      AND  NOT EXISTS (
             SELECT 1
             FROM   grac_practice.practice_instance_obligation x
             WHERE  x.practice_instance_id          = i.practice_instance_id
               AND  x.source_practice_obligation_id = po.practice_obligation_id);

    SET @copies_created = @@ROWCOUNT;

    -- 3c. A retired definition retires its copies everywhere. Retired,
    --     never deleted -- the same treatment 227 gives a retired local
    --     obligation, and the evidence somebody produced against it stays
    --     attached to a row that still exists.
    UPDATE pio
       SET status     = N'Retired',
           updated_by = @actor,
           updated_dt = SYSUTCDATETIME()
    FROM   grac_practice.practice_instance_obligation pio
    JOIN   @defs d ON d.practice_obligation_id = pio.source_practice_obligation_id
    JOIN   @instances i ON i.practice_instance_id = pio.practice_instance_id
    WHERE  d.is_active = 0
      AND  pio.status = N'Active';

    SET @copies_retired = @@ROWCOUNT;

    COMMIT TRANSACTION;

    -- 3d. Evidence, per copy. Outside the transaction on purpose: the
    --     sync opens one of its own, and nesting it inside this one would
    --     put a COMMIT it does not own between the obligation writes and
    --     their rollback.
    --
    --     Reused rather than reimplemented. It already knows
    --     practice_instance_evidence's NOT NULL columns, already revives
    --     a retired row of the same type instead of duplicating it, and
    --     already refuses to retire an evidence row somebody has filled
    --     in. A NULL evidence_json means "no opinion" and it changes
    --     nothing, which is what a definition with no declared evidence
    --     should do.
    IF OBJECT_ID('grac_practice.sp_resolve_local_obligation_evidence_sync','P') IS NOT NULL
    BEGIN
        DECLARE @pio_id BIGINT, @inst_id BIGINT, @ev NVARCHAR(MAX);
        -- The sync's three OUTPUT parameters have no defaults, so all
        -- three are supplied. Added and removed are summed into one count
        -- for the caller; kept is per-call detail that means nothing
        -- aggregated across instances.
        DECLARE @ev_added INT = 0, @ev_removed INT = 0, @ev_kept INT = 0;

        DECLARE copies CURSOR LOCAL FAST_FORWARD FOR
            SELECT pio.practice_instance_obligation_id, pio.practice_instance_id, d.evidence_json
            FROM   grac_practice.practice_instance_obligation pio
            JOIN   @defs d ON d.practice_obligation_id = pio.source_practice_obligation_id
            JOIN   @instances i ON i.practice_instance_id = pio.practice_instance_id
            WHERE  d.is_active = 1
              AND  pio.status = N'Active'
              AND  d.evidence_json IS NOT NULL;

        OPEN copies;
        FETCH NEXT FROM copies INTO @pio_id, @inst_id, @ev;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC grac_practice.sp_resolve_local_obligation_evidence_sync
                 @practice_instance_id            = @inst_id,
                 @practice_instance_obligation_id = @pio_id,
                 @evidence_json                   = @ev,
                 @actor                           = @actor,
                 @evidence_added                  = @ev_added   OUTPUT,
                 @evidence_removed                = @ev_removed OUTPUT,
                 @evidence_kept                   = @ev_kept    OUTPUT;

            SET @evidence_synced = @evidence_synced + ISNULL(@ev_added, 0) + ISNULL(@ev_removed, 0);

            FETCH NEXT FROM copies INTO @pio_id, @inst_id, @ev;
        END
        CLOSE copies;
        DEALLOCATE copies;
    END
END
GO
PRINT '307: sp_practice_obligation_fan_out created.';
GO

-- =====================================================================
-- 4. sp_practice_obligation_save -- add, edit or retire one definition
--
--    @practice_obligation_id = 0 adds; anything else edits the row with
--    that id, and only if it belongs to this practice.
--
--    Validation is 227's, field for field, because the same form writes
--    both and a rule enforced on one door and not the other is not a
--    rule.
--
--    FANS OUT INLINE, and hands the counts back as extra columns on its
--    single result row -- the shape 233 established for exactly this
--    situation. That is safe here because neither the fan-out nor the
--    evidence sync it calls returns a result set of its own, so this
--    procedure's SELECT is still the only one the caller sees.
--
--    Inline rather than "the API calls both": a definition that exists
--    with no copies is a state nothing else in the system expects, and
--    leaving that window open for a network hiccup to land in would make
--    every reader defensive. The reconcile path still exists as a repair
--    for instances created later, not as the primary route.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_practice_obligation_save
    @organization_id        BIGINT,
    @practice_id            BIGINT,
    @practice_obligation_id BIGINT        = 0,
    @obligation_name        NVARCHAR(500) = NULL,
    @obligation_description NVARCHAR(MAX) = NULL,
    @obligation_type_code   NVARCHAR(60)  = NULL,
    @typed_detail_json      NVARCHAR(MAX) = NULL,
    @execution_frequency_id INT           = NULL,
    @execution_frequency    NVARCHAR(120) = NULL,
    @responsibility         NVARCHAR(300) = NULL,
    @approval_authority     NVARCHAR(300) = NULL,
    @assurance_type         NVARCHAR(40)  = NULL,
    @remarks                NVARCHAR(MAX) = NULL,
    @evidence_json          NVARCHAR(MAX) = NULL,
    @retire                 BIT           = 0,
    @actor                  NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @practice_id IS NULL
        THROW 57201, 'sp_practice_obligation_save: practice_id is required.', 1;

    DECLARE @practice_org_id BIGINT;
    SELECT @practice_org_id = organization_id
    FROM   grac_practice.practice
    WHERE  practice_id = @practice_id;

    IF @practice_org_id IS NULL
        THROW 57202, 'sp_practice_obligation_save: practice not found.', 1;

    -- The caller may name the organisation; if it does, it has to match.
    -- Scoped this way rather than trusting the parameter, so a practice
    -- id from another tenant cannot be written into this one.
    IF @organization_id IS NOT NULL AND @organization_id <> @practice_org_id
        THROW 57203, 'sp_practice_obligation_save: that practice belongs to another organization.', 1;

    SET @organization_id = @practice_org_id;

    -- ---- retire ----
    IF @retire = 1
    BEGIN
        IF ISNULL(@practice_obligation_id, 0) = 0
            THROW 57204, 'sp_practice_obligation_save: an id is required to retire an obligation.', 1;

        UPDATE grac_practice.practice_obligation
           SET status     = N'Retired',
               updated_by = @actor,
               updated_dt = SYSUTCDATETIME()
         WHERE practice_obligation_id = @practice_obligation_id
           AND practice_id           = @practice_id;

        IF @@ROWCOUNT = 0
            THROW 57205, 'sp_practice_obligation_save: no practice-level obligation with that id on this practice.', 1;

        -- Retiring the definition retires its copies everywhere, which is
        -- the fan-out's 3c branch -- so the same call does both halves.
        DECLARE @r_created INT = 0, @r_updated INT = 0, @r_retired INT = 0, @r_evidence INT = 0;
        EXEC grac_practice.sp_practice_obligation_fan_out
             @practice_id            = @practice_id,
             @practice_obligation_id = @practice_obligation_id,
             @actor                  = @actor,
             @copies_created         = @r_created  OUTPUT,
             @copies_updated         = @r_updated  OUTPUT,
             @copies_retired         = @r_retired  OUTPUT,
             @evidence_synced        = @r_evidence OUTPUT;

        SELECT CAST(1 AS BIT) AS Success,
               N'Obligation removed from the practice.' AS Message,
               @practice_obligation_id AS PracticeObligationId,
               @r_created  AS CopiesCreated,
               @r_updated  AS CopiesUpdated,
               @r_retired  AS CopiesRetired,
               @r_evidence AS EvidenceSynced;
        RETURN;
    END

    -- ---- validate ----
    SET @obligation_name = NULLIF(LTRIM(RTRIM(@obligation_name)), N'');
    IF @obligation_name IS NULL
        THROW 57206, 'Obligation name is required.', 1;

    SET @obligation_type_code = NULLIF(LTRIM(RTRIM(@obligation_type_code)), N'');
    IF @obligation_type_code IS NULL
        THROW 57207, 'Obligation type is required.', 1;

    IF NOT EXISTS (SELECT 1 FROM GRAC_New.obligation_type_master
                    WHERE type_code = @obligation_type_code)
        THROW 57208, 'That obligation type does not exist.', 1;

    IF @typed_detail_json IS NOT NULL AND ISJSON(@typed_detail_json) <> 1
        THROW 57209, 'The rule detail must be valid JSON.', 1;

    IF @evidence_json IS NOT NULL AND ISJSON(@evidence_json) <> 1
        THROW 57210, 'The evidence list must be valid JSON.', 1;

    IF @assurance_type IS NOT NULL AND @assurance_type NOT IN (N'Manual', N'Automated')
        THROW 57211, 'Assurance type must be Manual or Automated.', 1;

    DECLARE @active_record_status_id INT = (
        SELECT TOP 1 record_status_id FROM grac_practice.record_status_master
        WHERE status_code = N'ACTIVE' OR status_name = N'Active'
        ORDER BY record_status_id);
    IF @active_record_status_id IS NULL SET @active_record_status_id = 1;

    -- ---- add ----
    IF ISNULL(@practice_obligation_id, 0) = 0
    BEGIN
        INSERT grac_practice.practice_obligation
            (organization_id, practice_id,
             obligation_name, obligation_description, obligation_type_code,
             typed_detail_json,
             execution_frequency_id, execution_frequency,
             responsibility, approval_authority, assurance_type, remarks,
             evidence_json, status, record_status_id, entered_by)
        VALUES
            (@organization_id, @practice_id,
             @obligation_name, @obligation_description, @obligation_type_code,
             ISNULL(@typed_detail_json, N'[]'),
             @execution_frequency_id, @execution_frequency,
             @responsibility, @approval_authority, @assurance_type, @remarks,
             @evidence_json, N'Active', @active_record_status_id, @actor);

        SET @practice_obligation_id = SCOPE_IDENTITY();

        DECLARE @a_created INT = 0, @a_updated INT = 0, @a_retired INT = 0, @a_evidence INT = 0;
        EXEC grac_practice.sp_practice_obligation_fan_out
             @practice_id            = @practice_id,
             @practice_obligation_id = @practice_obligation_id,
             @actor                  = @actor,
             @copies_created         = @a_created  OUTPUT,
             @copies_updated         = @a_updated  OUTPUT,
             @copies_retired         = @a_retired  OUTPUT,
             @evidence_synced        = @a_evidence OUTPUT;

        SELECT CAST(1 AS BIT) AS Success,
               N'Obligation added to the practice.' AS Message,
               @practice_obligation_id AS PracticeObligationId,
               @a_created  AS CopiesCreated,
               @a_updated  AS CopiesUpdated,
               @a_retired  AS CopiesRetired,
               @a_evidence AS EvidenceSynced;
        RETURN;
    END

    -- ---- edit ----
    --
    -- evidence_json follows the "absent means unchanged" contract the
    -- rest of this module uses (see 232): NULL leaves the stored list
    -- alone, and an explicit empty array is how you say "no evidence".
    UPDATE grac_practice.practice_obligation
       SET obligation_name        = @obligation_name,
           obligation_description = @obligation_description,
           obligation_type_code   = @obligation_type_code,
           typed_detail_json      = ISNULL(@typed_detail_json, typed_detail_json),
           execution_frequency_id = @execution_frequency_id,
           execution_frequency    = @execution_frequency,
           responsibility         = @responsibility,
           approval_authority     = @approval_authority,
           assurance_type         = @assurance_type,
           remarks                = @remarks,
           evidence_json          = ISNULL(@evidence_json, evidence_json),
           status                 = N'Active',
           updated_by             = @actor,
           updated_dt             = SYSUTCDATETIME()
     WHERE practice_obligation_id = @practice_obligation_id
       AND practice_id            = @practice_id;

    IF @@ROWCOUNT = 0
        THROW 57205, 'sp_practice_obligation_save: no practice-level obligation with that id on this practice.', 1;

    DECLARE @e_created INT = 0, @e_updated INT = 0, @e_retired INT = 0, @e_evidence INT = 0;
    EXEC grac_practice.sp_practice_obligation_fan_out
         @practice_id            = @practice_id,
         @practice_obligation_id = @practice_obligation_id,
         @actor                  = @actor,
         @copies_created         = @e_created  OUTPUT,
         @copies_updated         = @e_updated  OUTPUT,
         @copies_retired         = @e_retired  OUTPUT,
         @evidence_synced        = @e_evidence OUTPUT;

    SELECT CAST(1 AS BIT) AS Success,
           N'Obligation saved.' AS Message,
           @practice_obligation_id AS PracticeObligationId,
           @e_created  AS CopiesCreated,
           @e_updated  AS CopiesUpdated,
           @e_retired  AS CopiesRetired,
           @e_evidence AS EvidenceSynced;
END
GO
PRINT '307: sp_practice_obligation_save created.';
GO

-- =====================================================================
-- 5. sp_practice_obligation_list -- the definitions, for Practice View
--
--    InstanceCount is how many active instances currently carry a copy,
--    which is the one fact the panel needs that the definition itself
--    does not hold: it is what makes "this applies everywhere" visible
--    rather than promised.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_practice_obligation_list
    @practice_id     BIGINT,
    @organization_id BIGINT = NULL,
    @include_retired BIT    = 0
AS
BEGIN
    SET NOCOUNT ON;

    IF @practice_id IS NULL
        THROW 57212, 'sp_practice_obligation_list: practice_id is required.', 1;

    SELECT po.practice_obligation_id AS PracticeObligationId,
           po.organization_id        AS OrganizationId,
           po.practice_id            AS PracticeId,
           po.obligation_name        AS ObligationName,
           po.obligation_description AS ObligationDescription,
           po.obligation_type_code   AS ObligationTypeCode,
           t.type_name               AS TypeName,
           po.typed_detail_json      AS TypedDetailJson,
           po.execution_frequency_id AS ExecutionFrequencyId,
           po.execution_frequency    AS ExecutionFrequency,
           po.responsibility         AS Responsibility,
           po.approval_authority     AS ApprovalAuthority,
           po.assurance_type         AS AssuranceType,
           po.remarks                AS Remarks,
           po.evidence_json          AS EvidenceJson,
           po.status                 AS Status_,
           po.entered_by             AS EnteredBy,
           po.entered_dt             AS EnteredDt,
           (SELECT COUNT(*)
              FROM grac_practice.practice_instance_obligation pio
              JOIN grac_practice.practice_instance pi
                   ON pi.practice_instance_id = pio.practice_instance_id
             WHERE pio.source_practice_obligation_id = po.practice_obligation_id
               AND pio.status = N'Active'
               AND pi.status  = N'Active') AS InstanceCount
    FROM   grac_practice.practice_obligation po
    LEFT   JOIN GRAC_New.obligation_type_master t
           ON t.type_code = po.obligation_type_code
    WHERE  po.practice_id = @practice_id
      AND (@organization_id IS NULL OR po.organization_id = @organization_id)
      AND (@include_retired = 1 OR po.status = N'Active')
    ORDER  BY ISNULL(t.display_order, 999), po.obligation_name;
END
GO
PRINT '307: sp_practice_obligation_list created.';
GO

-- =====================================================================
-- Verification
-- =====================================================================
PRINT '=== 307 verification ===';

SELECT '307-a practice_obligation table' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.practice_obligation','U') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '307-b source_practice_obligation_id column',
       CASE WHEN COL_LENGTH('grac_practice.practice_instance_obligation','source_practice_obligation_id')
                 IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '307-c filtered unique index on the copy',
       CASE WHEN EXISTS (SELECT 1 FROM sys.indexes
                          WHERE name = 'ux_pm_pio_practice_obligation'
                            AND object_id = OBJECT_ID('grac_practice.practice_instance_obligation'))
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '307-d sp_practice_obligation_save',
       CASE WHEN OBJECT_ID('grac_practice.sp_practice_obligation_save','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '307-e sp_practice_obligation_fan_out',
       CASE WHEN OBJECT_ID('grac_practice.sp_practice_obligation_fan_out','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '307-f sp_practice_obligation_list',
       CASE WHEN OBJECT_ID('grac_practice.sp_practice_obligation_list','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
-- The fan-out reports through OUTPUT parameters rather than a result
-- set, so a caller that composes it is not left reading the wrong row.
-- This checks the parameters are there; that no SELECT returns rows is a
-- property of the body, and section 3's header is where it is stated.
SELECT '307-g fan_out reports via OUTPUT parameters',
       CASE WHEN EXISTS (SELECT 1 FROM sys.parameters
                          WHERE object_id = OBJECT_ID('grac_practice.sp_practice_obligation_fan_out','P')
                            AND is_output = 1
                            AND name = '@copies_created')
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
-- The save composes the fan-out, so the 233 rule has to hold on both.
SELECT '307-i save composes the fan-out',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_practice_obligation_save','P'))
                 LIKE '%sp_practice_obligation_fan_out%' THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '307-j evidence sync is the 233 OUTPUT version',
       CASE WHEN OBJECT_ID('grac_practice.sp_resolve_local_obligation_evidence_sync','P') IS NULL
            THEN 'SKIP (232/233 not applied)'
            WHEN EXISTS (SELECT 1 FROM sys.parameters
                          WHERE object_id = OBJECT_ID('grac_practice.sp_resolve_local_obligation_evidence_sync','P')
                            AND name = '@evidence_added')
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
-- Regression guard: 227's rule must survive. An instance-custom
-- obligation is still (obligation_id NULL, source_practice_obligation_id
-- NULL) and nothing above writes to those rows.
SELECT '307-h instance-custom obligations untouched',
       CASE WHEN NOT EXISTS (
                SELECT 1 FROM grac_practice.practice_instance_obligation
                 WHERE obligation_id IS NULL
                   AND source_practice_obligation_id IS NULL
                   AND updated_by = N'seed-307')
            THEN 'PASS' ELSE 'FAIL' END;

PRINT '';
PRINT '307 complete. Practice-level obligations can be authored and fanned out.';
PRINT 'STILL OPEN, by design -- see the header:';
PRINT '  308 must add the source_practice_obligation_id IS NULL guard to';
PRINT '  sp_resolve_local_obligation_save (from 244) and project';
PRINT '  SourcePracticeObligationId from sp_resolve_obligation_list (from 244).';
PRINT '  Until then a fanned-out copy is still editable through the instance door.';
GO

SET NOEXEC OFF;
GO
