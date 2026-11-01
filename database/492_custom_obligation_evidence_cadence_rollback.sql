-- =====================================================================
-- 492_custom_obligation_evidence_cadence_rollback.sql
-- Restores the 463 sync procedure and the 475 cadence view verbatim, then
-- drops practice_instance_evidence.evidence_cadence (custom evidence reads
-- Recurring again). SAFE TO RE-RUN. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
GO

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


CREATE OR ALTER VIEW grac_practice.vw_pm_instance_evidence_cadence
AS
    -- 473: the cadence of every practice_instance_evidence row.
    -- 475: the by-type branch maps evidence types by name (see below).
    --   Published = read from the organisation's copy of the specs of
    --               this obligation + evidence type (any Recurring spec
    --               makes the row Recurring), or, failing that, of the
    --               exact spec the row was created from;
    --   Default   = nothing published (organisation-defined evidence)
    --               -> Recurring, the 077 default.
    -- A copied spec with no cadence (a copy still waiting for approval of
    -- the 077 change) reads as Recurring, the same as 077's backfill.
    SELECT e.evidence_id,
           e.organization_id,
           e.practice_instance_id,
           c.EvidenceCadence,
           COALESCE(ro.option_label, c.EvidenceCadence) AS EvidenceCadenceLabel,
           c.CadenceSource
    FROM   grac_practice.practice_instance_evidence e
    OUTER  APPLY (
        SELECT COUNT(*) AS spec_count,
               MAX(CASE WHEN ISNULL(ooe.evidence_cadence, N'Recurring') = N'OneTime' THEN 0 ELSE 1 END) AS any_recurring
        FROM   grac_practice.vw_pm_obligation_evidence oe
        JOIN   grac_practice.organization_obligation_evidence ooe
               ON ooe.organization_id = oe.organization_id
              AND ooe.obligation_evidence_id = oe.obligation_evidence_id
        -- 475: oe.evidence_type_id is a GRAC_New evidence type and
        -- e.evidence_type_id a Practice Management one -- two masters. Map
        -- by name, the way sp_resolve_evidence_list (306/473) does.
        JOIN   GRAC_New.evidence_type_master get
               ON get.evidence_type_id = oe.evidence_type_id
        JOIN   grac_practice.evidence_type_master pet
               ON pet.evidence_type_name = get.evidence_type_name
              AND pet.is_active = 1
        WHERE  e.source_obligation_id IS NOT NULL
          AND  oe.organization_id  = e.organization_id
          AND  oe.obligation_id    = e.source_obligation_id
          AND  pet.evidence_type_id = e.evidence_type_id
    ) bytype
    OUTER  APPLY (
        SELECT TOP 1 ISNULL(ooe2.evidence_cadence, N'Recurring') AS cadence
        FROM   grac_practice.organization_obligation_evidence ooe2
        WHERE  e.source_obligation_evidence_id IS NOT NULL
          AND  ooe2.organization_id = e.organization_id
          AND  ooe2.obligation_evidence_id = e.source_obligation_evidence_id
    ) exact
    CROSS  APPLY (
        SELECT CASE WHEN bytype.spec_count > 0
                    THEN CASE WHEN bytype.any_recurring = 1 THEN N'Recurring' ELSE N'OneTime' END
                    WHEN exact.cadence IS NOT NULL THEN exact.cadence
                    ELSE N'Recurring' END AS EvidenceCadence,
               CASE WHEN bytype.spec_count > 0 OR exact.cadence IS NOT NULL
                    THEN N'Published' ELSE N'Default' END AS CadenceSource
    ) c
    LEFT   JOIN GRAC_New.reference_option ro
           ON ro.option_group = N'evidence-cadence'
          AND ro.option_value = c.EvidenceCadence;
GO


IF EXISTS (SELECT 1 FROM sys.check_constraints
            WHERE name = 'ck_pm_instance_evidence_cadence'
              AND parent_object_id = OBJECT_ID('grac_practice.practice_instance_evidence'))
    ALTER TABLE grac_practice.practice_instance_evidence DROP CONSTRAINT ck_pm_instance_evidence_cadence;
GO
IF COL_LENGTH('grac_practice.practice_instance_evidence','evidence_cadence') IS NOT NULL
    ALTER TABLE grac_practice.practice_instance_evidence DROP COLUMN evidence_cadence;
GO
SELECT '492 rollback' AS Check_,
       CASE WHEN COL_LENGTH('grac_practice.practice_instance_evidence','evidence_cadence') IS NULL THEN 'PASS' ELSE 'FAIL' END AS Result_;
GO
