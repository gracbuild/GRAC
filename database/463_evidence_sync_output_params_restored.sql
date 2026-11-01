-- =====================================================================
-- 463_evidence_sync_output_params_restored.sql
--
-- THE FAULT
-- ---------
-- Practice View -> Actions -> Add Obligation -> Save fails with
--
--   "Procedure or function sp_resolve_local_obligation_evidence_sync has
--    too many arguments specified."
--
-- Every other obligation save that carries evidence fails the same way:
-- Operationalize -> Add / Edit obligation (sp_resolve_local_obligation_save)
-- and the practice fan-out (sp_practice_obligation_fan_out).
--
-- WHY
-- ---
-- 232 created the sync with FOUR parameters and ended it with
--
--     SELECT @added AS EvidenceAdded, @removed AS ..., @kept AS ...
--
-- 233 fixed that: a SELECT inside a called procedure is NOT private to it
-- -- it becomes the CALLER's first result set, so the API read a row with
-- no [Message] column, reported a failure for a save that had already
-- committed, and the dialog stayed open and inserted again on every click.
-- 233 replaced the SELECT with three OUTPUT parameters, taking the proc to
-- SEVEN parameters. 242, 244, 307, 340_custom and 412 all call it that way.
--
-- 340_local_obligation_evidence_description re-issued the proc from the
-- 232 body instead of the 233 body ("Requires 232 (the proc this
-- re-issues)"), silently dropping the three OUTPUT parameters AND
-- reinstating the trailing SELECT. 397 then re-issued 340's body
-- ("DEPENDS ON: 340 (current proc body)") and carried the regression
-- forward. So the live proc is back to four parameters while every caller
-- passes seven -- hence the error, on every evidence-bearing save path.
--
-- WHAT THIS DOES
-- --------------
-- Re-issues sp_resolve_local_obligation_evidence_sync with 397's body --
-- the shared-id (GRAC_New) evidence_type translation from 397 and the
-- evidence_description writes from 340, both kept verbatim -- on 233's
-- SEVEN-parameter signature:
--
--   + @evidence_added   INT OUTPUT
--   + @evidence_removed INT OUTPUT
--   + @evidence_kept    INT OUTPUT
--   - the trailing SELECT (233's fix, restored)
--
-- The counts are initialised to 0 up front so an early RETURN cannot leave
-- the caller's variables holding stale values, and are set from @@ROWCOUNT
-- at exactly the points 233 set them.
--
-- NO caller changes. 412's sp_resolve_local_obligation_save and
-- sp_practice_obligation_fan_out are already correct and are NOT touched.
-- No schema change, no data migration, no API change.
--
-- Re-issued from: 397 (body) + 233 (signature and count handling).
-- SAFE TO RE-RUN (CREATE OR ALTER). Requires 232, 233, 340, 397.
-- Rollback: database/463_evidence_sync_output_params_restored_rollback.sql
-- ASCII-only on purpose: sqlcmd reads files in the current ANSI codepage
-- by default and multi-byte characters can corrupt string literals.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;   -- defensive: reset in case a prior script left it on
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

-- Guard on the COLUMNS and OBJECTS this body reads, not merely on the
-- proc existing: this script re-issues an earlier migration's body, so a
-- database missing any of them would take a proc that cannot run.
IF OBJECT_ID('grac_practice.sp_resolve_local_obligation_evidence_sync','P') IS NULL
   OR OBJECT_ID('grac_practice.practice_instance_evidence','U') IS NULL
   OR OBJECT_ID('grac_practice.evidence_type_master','U') IS NULL
   OR OBJECT_ID('GRAC_New.evidence_type_master','U') IS NULL
   OR OBJECT_ID('grac_practice.collection_method_master','U') IS NULL
   OR OBJECT_ID('grac_practice.evidence_alignment_status_master','U') IS NULL
   OR OBJECT_ID('grac_practice.record_status_master','U') IS NULL
BEGIN
    PRINT 'ABORT (463): run 232 / 233 / 340 / 397 and the evidence masters first.';
    SET NOEXEC ON;
END
GO

IF COL_LENGTH('grac_practice.practice_instance_evidence','evidence_description') IS NULL
   OR COL_LENGTH('grac_practice.practice_instance_evidence','source_practice_instance_obligation_id') IS NULL
   OR COL_LENGTH('grac_practice.evidence_type_master','evidence_type_name') IS NULL
   OR COL_LENGTH('GRAC_New.evidence_type_master','evidence_type_name') IS NULL
BEGIN
    PRINT 'ABORT (463): evidence_description / evidence link / evidence_type_name column missing -- run 231, 340 first.';
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- sp_resolve_local_obligation_evidence_sync
--   body from 397, signature and count handling from 233
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_resolve_local_obligation_evidence_sync
    @practice_instance_id            BIGINT,
    @practice_instance_obligation_id BIGINT,
    @evidence_json                   NVARCHAR(MAX) = NULL,
    @actor                           NVARCHAR(100) = N'system',
    -- 233: OUTPUT, not a result set. A SELECT here becomes the FIRST
    -- result set of the CALLER and the caller's own Success / Message row
    -- is never read. Restored by 463 after 340/397 dropped it.
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

    -- 340: `remarks` from the form is the evidence Description. Parsed here
    -- and written to evidence_description in every arm below.
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

    -- 397: standardize practice_instance_evidence.evidence_type_id on the
    -- SHARED catalogue id. The obligation dialog posts
    -- grac_practice.evidence_type_master ids, but the column is FK'd to
    -- GRAC_New.evidence_type_master (fk_pm_evidence_shared_type) and every
    -- reader/writer must agree on one id space. The two masters carry the same
    -- names; translate the posted local id to the matching SHARED id BY NAME so
    -- the row satisfies the FK even where the two id sequences have diverged
    -- between environments (the cause of the fk_pm_evidence_shared_type
    -- conflict on obligation save in a UAT database). No data migration is
    -- needed: existing rows already hold shared ids (the FK has enforced it
    -- since 002); only the newly-inserted id had to be corrected.
    IF EXISTS (
        SELECT 1 FROM @want w
        WHERE NOT EXISTS (
            SELECT 1
            FROM   grac_practice.evidence_type_master pet
            JOIN   GRAC_New.evidence_type_master get
                   ON get.evidence_type_name = pet.evidence_type_name AND get.is_active = 1
            WHERE  pet.evidence_type_id = w.evidence_type_id))
        THROW 52706, 'An evidence type is not present in the shared evidence catalogue and cannot be saved.', 1;

    UPDATE w
       SET evidence_type_id = get.evidence_type_id
    FROM   @want w
    JOIN   grac_practice.evidence_type_master pet ON pet.evidence_type_id = w.evidence_type_id
    JOIN   GRAC_New.evidence_type_master      get ON get.evidence_type_name = pet.evidence_type_name AND get.is_active = 1;

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
       SET status              = N'Active',
           is_mandatory        = w.is_mandatory,
           retention_period    = COALESCE(w.retention_period, pie.retention_period),
           -- 340: the dialog owns the Description while it is open (modal,
           -- so no concurrent inline edit), and the dialog seed re-reads
           -- this column -- so the sent value is authoritative and a blank
           -- box clears it.
           evidence_description = w.remarks,
           updated_by          = @actor,
           updated_dt          = SYSUTCDATETIME()
    FROM   grac_practice.practice_instance_evidence pie
    JOIN   @want w ON w.evidence_type_id = pie.evidence_type_id
    WHERE  pie.practice_instance_id = @practice_instance_id
      AND  pie.source_practice_instance_obligation_id = @practice_instance_obligation_id
      AND  pie.status <> N'Active';

    -- 1b. Update the ones already active.
    UPDATE pie
       SET is_mandatory        = w.is_mandatory,
           retention_period    = COALESCE(w.retention_period, pie.retention_period),
           evidence_description = w.remarks,   -- 340, see 1a
           updated_by          = @actor,
           updated_dt          = SYSUTCDATETIME()
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
         evidence_description,
         alignment_status_id, source_obligation_id,
         source_practice_instance_obligation_id,
         status, record_status_id, entered_by)
    SELECT @organization_id, @practice_instance_id, w.evidence_type_id,
           0, 1, w.is_mandatory,
           @collection_method_id, NULL, w.retention_period,
           w.remarks,                          -- 340: the evidence Description
           @alignment_status_id, NULL,
           @practice_instance_obligation_id,
           N'Active', @active_record_status_id, @actor
    FROM   @want w
    WHERE  NOT EXISTS (SELECT 1 FROM grac_practice.practice_instance_evidence x
                        WHERE x.practice_instance_id = @practice_instance_id
                          AND x.source_practice_instance_obligation_id = @practice_instance_obligation_id
                          AND x.evidence_type_id = w.evidence_type_id);

    -- 233: OUTPUT, not DECLARE. @@ROWCOUNT is read on the very next
    -- statement, exactly where 232/397 declared @added.
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
    -- No SELECT here. See 233 and the header: a result set from this proc
    -- becomes the caller's FIRST result set and hides its Success/Message
    -- row, which is reported to the user as a failed save of a committed
    -- obligation -- and makes the next Save insert a duplicate.
END
GO

-- =====================================================================
-- Verification
-- =====================================================================
PRINT '=== 463 verification ===';

SELECT '463 sync takes 7 parameters (233 signature)' AS Check_,
       CASE WHEN (SELECT COUNT(*) FROM sys.parameters
                  WHERE object_id = OBJECT_ID('grac_practice.sp_resolve_local_obligation_evidence_sync','P')) = 7
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '463 the three counts are OUTPUT',
       CASE WHEN (SELECT COUNT(*) FROM sys.parameters
                  WHERE object_id = OBJECT_ID('grac_practice.sp_resolve_local_obligation_evidence_sync','P')
                    AND is_output = 1
                    AND name IN ('@evidence_added','@evidence_removed','@evidence_kept')) = 3
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '463 no result set left in the body (233 fix restored)',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_resolve_local_obligation_evidence_sync','P'))
                 NOT LIKE '%SELECT @added AS EvidenceAdded%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '463 keeps 397 shared-id translation',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_resolve_local_obligation_evidence_sync','P'))
                 LIKE '%get.evidence_type_name = pet.evidence_type_name%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '463 keeps 340 evidence_description writes',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_resolve_local_obligation_evidence_sync','P'))
                 LIKE '%evidence_description = w.remarks%'
            THEN 'PASS' ELSE 'FAIL' END;
GO

SET NOEXEC OFF;
GO
