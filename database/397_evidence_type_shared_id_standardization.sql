-- =====================================================================
-- 397  Evidence type: store the SHARED (GRAC_New) evidence_type_id on
--      obligation-evidence save (Operationalize)
--
-- BUG
-- ---
--   Saving obligation evidence in Operationalize failed with:
--     "The INSERT statement conflicted with the FOREIGN KEY constraint
--      fk_pm_evidence_shared_type ... GRAC_New.evidence_type_master."
--
--   grac_practice.practice_instance_evidence.evidence_type_id is FK'd to the
--   SHARED catalogue GRAC_New.evidence_type_master, but
--   sp_resolve_local_obligation_evidence_sync validated against and inserted
--   the LOCAL grac_practice.evidence_type_master id. The two masters carry the
--   same evidence-type NAMES but their id sequences can differ per
--   environment. Where they coincide (dev) the insert happened to satisfy the
--   FK; where they have diverged (UAT) the local id is absent from the shared
--   master and the FK rejects the row.
--
-- FIX (this migration)
-- --------------------
--   Re-issue sp_resolve_local_obligation_evidence_sync so that, after the
--   existing local validation, it translates each posted local evidence_type_id
--   to the matching SHARED id BY NAME and stores THAT. The rest of the proc is
--   unchanged and now runs entirely on shared ids, matching the FK and the
--   existing rows (which already hold shared ids -- the FK has enforced that
--   since 002, so NO data migration is required).
--
-- NOTE -- same latent issue on the REPOSITORY paths
--   sp_resolve_obligation_adopt (adoption) and the on-load evidence reconcile
--   also insert the LOCAL id (pet.evidence_type_id). They break the same way
--   for repository-inherited obligations when the two masters diverge and
--   should be re-issued to store get.evidence_type_id (the shared id) the same
--   way. Left out of this migration deliberately: this one fixes the reported
--   org-defined obligation save path; the repository paths are a follow-up so
--   each large proc is changed and verified on its own.
--
-- DEPENDS ON: 340 (current proc body), 002 (fk_pm_evidence_shared_type),
--   GRAC_New.evidence_type_master, grac_practice.evidence_type_master.
-- Rollback: 397_evidence_type_shared_id_standardization_rollback.sql
--   (re-issues the 340 body verbatim, i.e. reverts to inserting the local id).
-- Re-runnable: yes (CREATE OR ALTER). ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

IF OBJECT_ID('GRAC_New.evidence_type_master','U') IS NULL
   OR OBJECT_ID('grac_practice.evidence_type_master','U') IS NULL
   OR OBJECT_ID('grac_practice.practice_instance_evidence','U') IS NULL
BEGIN
    RAISERROR('397: required evidence tables missing. Run 001/002 first.', 16, 1);
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_resolve_local_obligation_evidence_sync
    @practice_instance_id            BIGINT,
    @practice_instance_obligation_id BIGINT,
    @evidence_json                   NVARCHAR(MAX) = NULL,
    @actor                           NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

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

    DECLARE @added INT = @@ROWCOUNT;

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

    DECLARE @removed INT = @@ROWCOUNT;

    -- 1e. What was kept because somebody had already worked on it.
    DECLARE @kept INT = (
        SELECT COUNT(*)
        FROM   grac_practice.practice_instance_evidence pie
        WHERE  pie.practice_instance_id = @practice_instance_id
          AND  pie.source_practice_instance_obligation_id = @practice_instance_obligation_id
          AND  pie.status = N'Active'
          AND  NOT EXISTS (SELECT 1 FROM @want w WHERE w.evidence_type_id = pie.evidence_type_id));

    COMMIT TRANSACTION;

    SELECT @added AS EvidenceAdded, @removed AS EvidenceRemoved, @kept AS EvidenceKept;
END
GO

-- =====================================================================
-- Verification
-- =====================================================================
PRINT '=== 397 verification ===';
SELECT '397 proc translates local id to shared id' AS Check_,
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_resolve_local_obligation_evidence_sync','P'))
                 LIKE '%get.evidence_type_name = pet.evidence_type_name%'
            THEN 'PASS' ELSE 'FAIL' END AS Result;
GO
