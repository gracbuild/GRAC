-- =====================================================================
-- 233 The evidence sync must not shift the caller's result set
--
-- THE FAULT
-- ---------
-- Saving an organisation-defined obligation reported a failure, left the
-- dialog open, and created a NEW obligation on every further click of
-- Save. Closing the dialog then showed one obligation per click.
--
-- Every one of those saves SUCCEEDED. The report of failure was wrong.
--
-- WHY
-- ---
-- 232 ended sp_resolve_local_obligation_evidence_sync with
--
--     SELECT @added AS EvidenceAdded, @removed AS EvidenceRemoved, ...
--
-- A SELECT inside a called procedure is not private to it. It becomes a
-- result set of the CALLER, and it comes back FIRST -- before the row
-- sp_resolve_local_obligation_save emits at the end.
--
-- So the API, reading the first row and asking for [Message], got a row
-- with only EvidenceAdded / EvidenceRemoved / EvidenceKept. Missing
-- column -> exception -> caught -> HTTP 400.
--
-- But the exception happened while READING, after the procedure had
-- already committed. The obligation was on disk; the screen was told it
-- was not. The dialog stayed open holding practiceInstanceObligationId
-- 0, so the next Save was another insert, not an update. Hence the
-- duplicates.
--
-- THE FIX
-- -------
-- The counts travel as OUTPUT parameters. The sync procedure now returns
-- no result set at all, and sp_resolve_local_obligation_save keeps
-- exactly ONE -- the row the caller reads -- with the counts as extra
-- columns on it.
--
-- This is the same hazard 217 was written to avoid, and the rule is
-- worth stating plainly:
--
--     A procedure that another procedure EXECs must not SELECT.
--     Use OUTPUT parameters.
--
-- The retire branch returns the three columns as zeroes so all three
-- branches have one shape, and the caller never has to test which one it
-- got.
--
-- WHAT ABOUT THE DUPLICATES ALREADY CREATED
-- -----------------------------------------
-- This script does NOT delete them. It cannot tell an accidental repeat
-- from two obligations an organisation deliberately gave the same name.
-- It lists them at the end, newest first, with their evidence counts, so
-- they can be removed from the screen -- which retires them properly and
-- retires their empty evidence with them.
--
-- SAFE TO RE-RUN. Requires 232.
-- ASCII-only (see 220's header for why).
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    PRINT 'ABORT (233): schema grac_practice missing.';
    SET NOEXEC ON;
END
GO

IF OBJECT_ID('grac_practice.sp_resolve_local_obligation_evidence_sync','P') IS NULL
BEGIN
    PRINT 'ABORT (233): sp_resolve_local_obligation_evidence_sync missing -- run 232 first.';
    SET NOEXEC ON;
END
GO

IF COL_LENGTH('grac_practice.practice_instance_evidence','source_practice_instance_obligation_id') IS NULL
BEGIN
    PRINT 'ABORT (233): evidence link column missing -- run 231 first.';
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. The sync procedure -- counts by OUTPUT, no result set
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_resolve_local_obligation_evidence_sync
    @practice_instance_id            BIGINT,
    @practice_instance_obligation_id BIGINT,
    @evidence_json                   NVARCHAR(MAX) = NULL,
    @actor                           NVARCHAR(100) = N'system',
    -- OUTPUT, not a result set. See the migration header: a SELECT here
    -- becomes the FIRST result set of the caller, and the caller's own
    -- Success / Message row is never read.
    @evidence_added                  INT OUTPUT,
    @evidence_removed                INT OUTPUT,
    @evidence_kept                   INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- Always initialised: an early RETURN must not leave the caller's
    -- variables holding whatever they had before.
    SET @evidence_added   = 0;
    SET @evidence_removed = 0;
    SET @evidence_kept    = 0;

    IF @evidence_json IS NULL RETURN;

    IF ISJSON(@evidence_json) <> 1
        THROW 52701, 'The evidence list must be a JSON array.', 1;

    DECLARE @organization_id BIGINT = (
        SELECT organization_id FROM grac_practice.practice_instance
        WHERE  practice_instance_id = @practice_instance_id);

    IF @organization_id IS NULL
        THROW 52702, 'sp_resolve_local_obligation_evidence_sync: instance not found.', 1;

    DECLARE @want TABLE (
        evidence_type_id INT PRIMARY KEY,
        is_mandatory     BIT,
        retention_period NVARCHAR(120) NULL,
        remarks          NVARCHAR(MAX) NULL
    );

    INSERT @want (evidence_type_id, is_mandatory, retention_period, remarks)
    SELECT j.EvidenceTypeId,
           ISNULL(j.IsMandatory, 1),
           NULLIF(LTRIM(RTRIM(j.RetentionPeriod)), N''),
           NULLIF(LTRIM(RTRIM(j.Remarks)), N'')
    FROM   OPENJSON(@evidence_json) WITH (
               EvidenceTypeId  INT           '$.evidenceTypeId',
               IsMandatory     BIT           '$.isMandatory',
               RetentionPeriod NVARCHAR(120) '$.retentionPeriod',
               Remarks         NVARCHAR(MAX) '$.remarks'
           ) j
    WHERE  j.EvidenceTypeId IS NOT NULL;

    IF EXISTS (SELECT 1 FROM @want w
                WHERE NOT EXISTS (SELECT 1 FROM grac_practice.evidence_type_master et
                                   WHERE et.evidence_type_id = w.evidence_type_id
                                     AND et.is_active = 1))
        THROW 52703, 'One of those evidence types does not exist.', 1;

    -- practice_instance_evidence.collection_method_id and
    -- alignment_status_id are NOT NULL, so both have to be resolved
    -- before a row can be written. Same resolution
    -- sp_resolve_obligation_adopt uses.
    DECLARE @collection_method_id INT = (
        SELECT TOP 1 collection_method_id FROM grac_practice.collection_method_master
        WHERE is_active = 1 AND (collection_method_code = N'Manual' OR collection_method_name = N'Manual')
        ORDER BY collection_method_id);
    IF @collection_method_id IS NULL
        SELECT TOP 1 @collection_method_id = collection_method_id
        FROM grac_practice.collection_method_master WHERE is_active = 1
        ORDER BY display_order, collection_method_id;
    IF @collection_method_id IS NULL
        THROW 52704, 'sp_resolve_local_obligation_evidence_sync: collection method master data is missing.', 1;

    -- An organisation-defined obligation is not inherited from anywhere,
    -- so its evidence starts life as organisation-defined too. Anything
    -- other than the Inherited status is the honest default; fall back to
    -- the first active one when the catalogue names it differently.
    DECLARE @alignment_status_id INT = (
        SELECT TOP 1 alignment_status_id FROM grac_practice.evidence_alignment_status_master
        WHERE is_active = 1 AND alignment_status_code = N'Organization'
        ORDER BY alignment_status_id);
    IF @alignment_status_id IS NULL
        SELECT TOP 1 @alignment_status_id = alignment_status_id
        FROM grac_practice.evidence_alignment_status_master WHERE is_active = 1
        ORDER BY display_order, alignment_status_id;
    IF @alignment_status_id IS NULL
        THROW 52705, 'sp_resolve_local_obligation_evidence_sync: evidence alignment status master data is missing.', 1;

    DECLARE @active_record_status_id INT = (
        SELECT TOP 1 record_status_id FROM grac_practice.record_status_master
        WHERE status_code = N'ACTIVE' OR status_name = N'Active' ORDER BY record_status_id);

    BEGIN TRANSACTION;

    -- 1a. Bring back a row of this type that was retired earlier, rather
    --     than creating a second one beside it.
    UPDATE pie
       SET status           = N'Active',
           is_mandatory     = w.is_mandatory,
           retention_period = COALESCE(w.retention_period, pie.retention_period),
           updated_by       = @actor,
           updated_dt       = SYSUTCDATETIME()
    FROM   grac_practice.practice_instance_evidence pie
    JOIN   @want w ON w.evidence_type_id = pie.evidence_type_id
    WHERE  pie.practice_instance_id = @practice_instance_id
      AND  pie.source_practice_instance_obligation_id = @practice_instance_obligation_id
      AND  pie.status <> N'Active';

    -- 1b. Update the ones already active.
    UPDATE pie
       SET is_mandatory     = w.is_mandatory,
           retention_period = COALESCE(w.retention_period, pie.retention_period),
           updated_by       = @actor,
           updated_dt       = SYSUTCDATETIME()
    FROM   grac_practice.practice_instance_evidence pie
    JOIN   @want w ON w.evidence_type_id = pie.evidence_type_id
    WHERE  pie.practice_instance_id = @practice_instance_id
      AND  pie.source_practice_instance_obligation_id = @practice_instance_obligation_id
      AND  pie.status = N'Active';

    -- 1c. Create what is missing.
    INSERT grac_practice.practice_instance_evidence
        (organization_id, practice_instance_id, evidence_type_id,
         inherited_from_repository, organization_modified, is_mandatory,
         collection_method_id, collection_frequency_id, retention_period,
         alignment_status_id, source_obligation_id,
         source_practice_instance_obligation_id,
         status, record_status_id, entered_by)
    SELECT @organization_id, @practice_instance_id, w.evidence_type_id,
           0, 1, w.is_mandatory,
           @collection_method_id, NULL, w.retention_period,
           @alignment_status_id, NULL,
           @practice_instance_obligation_id,
           N'Active', @active_record_status_id, @actor
    FROM   @want w
    WHERE  NOT EXISTS (SELECT 1 FROM grac_practice.practice_instance_evidence x
                        WHERE x.practice_instance_id = @practice_instance_id
                          AND x.source_practice_instance_obligation_id = @practice_instance_obligation_id
                          AND x.evidence_type_id = w.evidence_type_id);

    SET @evidence_added = @@ROWCOUNT;

    -- 1d. Retire what is no longer wanted -- but only the empty ones.
    UPDATE pie
       SET status     = N'Retired',
           updated_by = @actor,
           updated_dt = SYSUTCDATETIME()
    FROM   grac_practice.practice_instance_evidence pie
    WHERE  pie.practice_instance_id = @practice_instance_id
      AND  pie.source_practice_instance_obligation_id = @practice_instance_obligation_id
      AND  pie.status = N'Active'
      AND  NOT EXISTS (SELECT 1 FROM @want w WHERE w.evidence_type_id = pie.evidence_type_id)
      AND  NULLIF(LTRIM(RTRIM(ISNULL(pie.evidence_location, N''))), N'') IS NULL
      AND  NULLIF(LTRIM(RTRIM(ISNULL(pie.evidence_locator,  N''))), N'') IS NULL
      AND  NULLIF(LTRIM(RTRIM(ISNULL(pie.evidence_owner,    N''))), N'') IS NULL;

    SET @evidence_removed = @@ROWCOUNT;

    -- 1e. What was kept because somebody had already worked on it.
    SET @evidence_kept = (
        SELECT COUNT(*)
        FROM   grac_practice.practice_instance_evidence pie
        WHERE  pie.practice_instance_id = @practice_instance_id
          AND  pie.source_practice_instance_obligation_id = @practice_instance_obligation_id
          AND  pie.status = N'Active'
          AND  NOT EXISTS (SELECT 1 FROM @want w WHERE w.evidence_type_id = pie.evidence_type_id));

    COMMIT TRANSACTION;
END
GO
PRINT '233: sp_resolve_local_obligation_evidence_sync returns no result set.';
GO

-- =====================================================================
-- 2. The save procedure -- one result set, counts carried on it
--
-- Body is 232's, unchanged apart from the three EXEC calls gaining
-- OUTPUT arguments and the three SELECTs gaining the count columns.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_resolve_local_obligation_save
    @practice_instance_id            BIGINT,
    @practice_instance_obligation_id BIGINT        = 0,
    @obligation_name                 NVARCHAR(500) = NULL,
    @obligation_description          NVARCHAR(MAX) = NULL,
    @obligation_type_code            NVARCHAR(60)  = NULL,
    @typed_detail_json               NVARCHAR(MAX) = NULL,
    @execution_frequency_id          INT           = NULL,
    @execution_frequency             NVARCHAR(120) = NULL,
    @responsibility                  NVARCHAR(300) = NULL,
    @approval_authority              NVARCHAR(300) = NULL,
    @assurance_type                  NVARCHAR(40)  = NULL,
    @remarks                         NVARCHAR(MAX) = NULL,
    -- [{ "evidenceTypeId": 3, "isMandatory": true, "retentionPeriod": "...",
    --    "remarks": "..." }, ...]  -- the complete desired set, like the
    -- dependency-category picker: this obligation's evidence is exactly
    -- this list, and anything of its own that is not in it is retired.
    @evidence_json                   NVARCHAR(MAX) = NULL,
    @retire                          BIT           = 0,
    @caller_employee_id              BIGINT        = NULL,
    @is_admin                        BIT           = 0,
    @actor                           NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @practice_instance_id IS NULL
        THROW 52691, 'sp_resolve_local_obligation_save: practice_instance_id is required.', 1;

    DECLARE @organization_id BIGINT, @owner_id BIGINT;
    SELECT @organization_id = organization_id, @owner_id = primary_owner_id
    FROM   grac_practice.practice_instance
    WHERE  practice_instance_id = @practice_instance_id;

    IF @organization_id IS NULL
        THROW 52692, 'sp_resolve_local_obligation_save: instance not found.', 1;

    -- Same ownership test every other Resolve procedure applies.
    IF @is_admin = 0 AND ISNULL(@owner_id, -1) <> ISNULL(@caller_employee_id, -2)
        THROW 52693, 'sp_resolve_local_obligation_save: this practice instance belongs to another owner.', 1;

    -- ---- retire ----
    IF @retire = 1
    BEGIN
        IF @practice_instance_obligation_id IS NULL OR @practice_instance_obligation_id = 0
            THROW 52694, 'sp_resolve_local_obligation_save: an id is required to retire an obligation.', 1;

        UPDATE grac_practice.practice_instance_obligation
           SET status     = N'Retired',
               updated_by = @actor,
               updated_dt = SYSUTCDATETIME()
         WHERE practice_instance_obligation_id = @practice_instance_obligation_id
           AND practice_instance_id            = @practice_instance_id
           AND obligation_id IS NULL;

        IF @@ROWCOUNT = 0
            THROW 52695, 'sp_resolve_local_obligation_save: no organisation-defined obligation with that id on this instance.', 1;

        -- Its evidence goes with it, but only what nobody has filled in --
        -- a row somebody has already located or assigned an owner to stays,
        -- exactly as sp_resolve_obligation_adopt treats an un-adopted
        -- published obligation. Their work is not this procedure's to
        -- throw away.
        UPDATE pie
           SET status     = N'Retired',
               updated_by = @actor,
               updated_dt = SYSUTCDATETIME()
        FROM   grac_practice.practice_instance_evidence pie
        WHERE  pie.practice_instance_id = @practice_instance_id
          AND  pie.source_practice_instance_obligation_id = @practice_instance_obligation_id
          AND  pie.status = N'Active'
          AND  NULLIF(LTRIM(RTRIM(ISNULL(pie.evidence_location, N''))), N'') IS NULL
          AND  NULLIF(LTRIM(RTRIM(ISNULL(pie.evidence_locator,  N''))), N'') IS NULL
          AND  NULLIF(LTRIM(RTRIM(ISNULL(pie.evidence_owner,    N''))), N'') IS NULL;

        SELECT CAST(1 AS BIT) AS Success, N'Obligation removed.' AS Message,
               @practice_instance_obligation_id AS PracticeInstanceObligationId,
               0 AS EvidenceAdded, 0 AS EvidenceRemoved, 0 AS EvidenceKept;
        RETURN;
    END

    -- ---- validate ----
    SET @obligation_name = NULLIF(LTRIM(RTRIM(@obligation_name)), N'');
    IF @obligation_name IS NULL
        THROW 52696, 'Obligation name is required.', 1;

    SET @obligation_type_code = NULLIF(LTRIM(RTRIM(@obligation_type_code)), N'');
    IF @obligation_type_code IS NULL
        THROW 52697, 'Obligation type is required.', 1;

    IF NOT EXISTS (SELECT 1 FROM GRAC_New.obligation_type_master
                    WHERE type_code = @obligation_type_code)
        THROW 52698, 'That obligation type does not exist.', 1;

    IF @typed_detail_json IS NOT NULL AND ISJSON(@typed_detail_json) <> 1
        THROW 52699, 'The rule detail must be valid JSON.', 1;

    IF @assurance_type IS NOT NULL AND @assurance_type NOT IN (N'Manual', N'Automated')
        THROW 52674, 'Assurance type must be Manual or Automated.', 1;

    IF @evidence_json IS NOT NULL AND ISJSON(@evidence_json) <> 1
        THROW 52701, 'The evidence list must be a JSON array.', 1;

    DECLARE @active_record_status_id INT = (
        SELECT TOP 1 record_status_id FROM grac_practice.record_status_master
        WHERE status_code = N'ACTIVE' OR status_name = N'Active' ORDER BY record_status_id);

    -- Counts come back through OUTPUT parameters so this procedure keeps
    -- exactly ONE result set -- the row the caller reads.
    DECLARE @ev_added INT = 0, @ev_removed INT = 0, @ev_kept INT = 0;

    -- ---- add ----
    IF ISNULL(@practice_instance_obligation_id, 0) = 0
    BEGIN
        INSERT grac_practice.practice_instance_obligation
            (organization_id, practice_instance_id, obligation_id, release_id,
             obligation_name, obligation_description, obligation_type_code,
             typed_detail_json,
             inherited_from_repository, organization_modified,
             execution_frequency_id, execution_frequency,
             responsibility, approval_authority, assurance_type, remarks,
             adopted_by, adopted_dt, status, record_status_id, entered_by)
        VALUES
            (@organization_id, @practice_instance_id, NULL, NULL,
             @obligation_name, @obligation_description, @obligation_type_code,
             ISNULL(@typed_detail_json, N'[]'),
             -- Not inherited, and organisation-defined is by definition
             -- an organisation modification.
             0, 1,
             @execution_frequency_id, @execution_frequency,
             @responsibility, @approval_authority, @assurance_type, @remarks,
             @actor, SYSUTCDATETIME(), N'Active', @active_record_status_id, @actor);

        SET @practice_instance_obligation_id = SCOPE_IDENTITY();

        EXEC grac_practice.sp_resolve_local_obligation_evidence_sync
             @practice_instance_id            = @practice_instance_id,
             @practice_instance_obligation_id = @practice_instance_obligation_id,
             @evidence_json                   = @evidence_json,
             @actor                           = @actor,
             @evidence_added                  = @ev_added   OUTPUT,
             @evidence_removed                = @ev_removed OUTPUT,
             @evidence_kept                   = @ev_kept    OUTPUT;

        SELECT CAST(1 AS BIT) AS Success, N'Obligation added.' AS Message,
               @practice_instance_obligation_id AS PracticeInstanceObligationId,
               @ev_added AS EvidenceAdded, @ev_removed AS EvidenceRemoved, @ev_kept AS EvidenceKept;
        RETURN;
    END

    -- ---- edit ----
    UPDATE grac_practice.practice_instance_obligation
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
           status                 = N'Active',
           updated_by             = @actor,
           updated_dt             = SYSUTCDATETIME()
     WHERE practice_instance_obligation_id = @practice_instance_obligation_id
       AND practice_instance_id            = @practice_instance_id
       -- The guard that matters: this door only opens on locally added
       -- rows. An adopted published obligation is edited through
       -- sp_resolve_obligation_adopt, which derives organization_modified
       -- against what was published -- a concept a local row has no
       -- counterpart for.
       AND obligation_id IS NULL;

    IF @@ROWCOUNT = 0
        THROW 52695, 'sp_resolve_local_obligation_save: no organisation-defined obligation with that id on this instance.', 1;

    EXEC grac_practice.sp_resolve_local_obligation_evidence_sync
         @practice_instance_id            = @practice_instance_id,
         @practice_instance_obligation_id = @practice_instance_obligation_id,
         @evidence_json                   = @evidence_json,
         @actor                           = @actor,
         @evidence_added                  = @ev_added   OUTPUT,
         @evidence_removed                = @ev_removed OUTPUT,
         @evidence_kept                   = @ev_kept    OUTPUT;

    SELECT CAST(1 AS BIT) AS Success, N'Obligation saved.' AS Message,
           @practice_instance_obligation_id AS PracticeInstanceObligationId,
           @ev_added AS EvidenceAdded, @ev_removed AS EvidenceRemoved, @ev_kept AS EvidenceKept;
END
GO
PRINT '233: sp_resolve_local_obligation_save keeps a single result set.';
GO

-- =====================================================================
-- Verification
-- =====================================================================
PRINT '=== 233 verification ===';

SELECT 'sync takes OUTPUT parameters' AS Check_,
       CASE WHEN EXISTS (
            SELECT 1 FROM sys.parameters
            WHERE object_id = OBJECT_ID('grac_practice.sp_resolve_local_obligation_evidence_sync','P')
              AND name = '@evidence_added' AND is_output = 1)
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT 'sync no longer SELECTs its counts',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_resolve_local_obligation_evidence_sync','P'))
                 LIKE '%SELECT @added AS EvidenceAdded%'
            THEN 'FAIL -- still shifts the caller''s result set' ELSE 'PASS' END
UNION ALL
SELECT 'save passes the counts back OUTPUT',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_resolve_local_obligation_save','P'))
                 LIKE '%@evidence_added  %= @ev_added   OUTPUT%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT 'all three branches return the same shape',
       CASE WHEN (LEN(OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_resolve_local_obligation_save','P')))
                - LEN(REPLACE(OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_resolve_local_obligation_save','P')),
                              'AS EvidenceAdded', ''))) / LEN('AS EvidenceAdded') = 3
            THEN 'PASS' ELSE 'FAIL -- expected 3 result rows carrying the counts' END;

-- Sanity: the save still emits Success and Message, which is the column
-- the API asks for and the one this whole migration exists to protect.
SELECT 'save still emits Success' AS Check_,
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_resolve_local_obligation_save','P'))
                 LIKE '%AS Success%' THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT 'save still emits Message',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_resolve_local_obligation_save','P'))
                 LIKE '%AS Message%' THEN 'PASS' ELSE 'FAIL' END;

PRINT '';
PRINT '=== Repeated obligation names -- likely the duplicate saves ===';
PRINT 'Remove the unwanted ones from the Operationalize screen. Deleting';
PRINT 'them here would skip the evidence retirement that goes with it.';

;WITH dup AS (
    SELECT pio.practice_instance_id,
           pio.obligation_name,
           pio.obligation_type_code,
           COUNT(*) OVER (PARTITION BY pio.practice_instance_id,
                                       pio.obligation_name,
                                       pio.obligation_type_code) AS Copies,
           pio.practice_instance_obligation_id,
           pio.entered_dt
    FROM   grac_practice.practice_instance_obligation pio
    WHERE  pio.obligation_id IS NULL
      AND  pio.status = N'Active'
)
SELECT dup.practice_instance_id            AS PracticeInstanceId,
       dup.obligation_name                 AS ObligationName,
       dup.obligation_type_code            AS TypeCode,
       dup.Copies                          AS Copies,
       dup.practice_instance_obligation_id AS AdoptionId,
       dup.entered_dt                      AS EnteredOn,
       (SELECT COUNT(*)
        FROM   grac_practice.practice_instance_evidence pie
        WHERE  pie.source_practice_instance_obligation_id = dup.practice_instance_obligation_id
          AND  pie.status = N'Active')      AS EvidenceRows
FROM   dup
WHERE  dup.Copies > 1
ORDER  BY dup.practice_instance_id, dup.obligation_name, dup.entered_dt DESC;

PRINT '';
PRINT '233 complete. Ship PracticeManagement.Api and PracticeManagement.Web with it.';
GO

SET NOEXEC OFF;
GO
