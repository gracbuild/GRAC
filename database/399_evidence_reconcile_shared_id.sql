-- =====================================================================
-- 399 Evidence reconcile stores the SHARED evidence_type_id
--
-- FIXES: "INSERT ... conflicted with the FOREIGN KEY constraint
--   fk_pm_evidence_shared_type ... GRAC_New.evidence_type_master" raised
--   when adopting/saving certain obligations in Operationalize.
--
-- CAUSE: grac_practice.practice_instance_evidence.evidence_type_id is FK'd
--   to the SHARED catalogue GRAC_New.evidence_type_master (002,
--   fk_pm_evidence_shared_type), but sp_resolve_evidence_reconcile_for_instance
--   translated the obligation's evidence type to the LOCAL
--   grac_practice.evidence_type_master id (by name) and stored THAT. The
--   two masters carry the same names but diverging ids per environment, so
--   a local id absent from GRAC_New broke the FK on INSERT. This is the same
--   defect 397 fixed in sp_resolve_local_obligation_evidence_sync; 397
--   explicitly deferred this adoption/reconcile path.
--
-- FIX: re-issue sp_resolve_evidence_reconcile_for_instance (live body from
--   394, logic otherwise unchanged) so both the source_obligation_id
--   back-fill (UPDATE ... CROSS APPLY) and the evidence INSERT use the
--   SHARED id get.evidence_type_id. The join to the local master (pet) is
--   kept only as a name filter, so which evidence types are adopted is
--   unchanged -- only the id that is stored/compared changes to the shared
--   one the FK expects. sp_resolve_obligation_adopt is unchanged; it calls
--   this procedure to create evidence, so the save path is fixed with it.
--
-- SCOPE: procedure body only. No schema or data change. Existing rows
--   already satisfy the FK (it was created only when every row did), so no
--   back-fill is required for the INSERT to stop failing.
--
-- DEPENDS ON: 394 (current proc body), 002 (fk_pm_evidence_shared_type).
-- Rollback: 399_..._rollback.sql re-issues the 394 body verbatim.
-- Re-runnable: yes (CREATE OR ALTER). ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID('GRAC_New.evidence_type_master','U') IS NULL
   OR OBJECT_ID('grac_practice.evidence_type_master','U') IS NULL
   THROW 52720, '399 requires both GRAC_New.evidence_type_master and grac_practice.evidence_type_master.', 1;
IF COL_LENGTH('grac_practice.practice_instance_evidence','evidence_type_id') IS NULL
   THROW 52720, '399 requires grac_practice.practice_instance_evidence.evidence_type_id.', 1;
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_resolve_evidence_reconcile_for_instance
    @practice_instance_id BIGINT,
    @actor                NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;

    IF @practice_instance_id IS NULL
        THROW 52630, 'sp_resolve_evidence_reconcile_for_instance: practice_instance_id is required.', 1;

    DECLARE @organization_id BIGINT;
    SELECT @organization_id = organization_id
    FROM   grac_practice.practice_instance
    WHERE  practice_instance_id = @practice_instance_id;

    -- RETURN, not THROW. This runs on a read path, and an instance that has
    -- been retired between the page loading and this call must not turn the
    -- workspace into an error.
    IF @organization_id IS NULL RETURN;

    DECLARE @active_record_status_id INT = (
        SELECT TOP 1 record_status_id FROM grac_practice.record_status_master
        WHERE status_code = 'ACTIVE' OR status_name = 'Active' ORDER BY record_status_id);
    IF @active_record_status_id IS NULL
        THROW 52609, 'sp_resolve_evidence_reconcile_for_instance: record status master data is missing.', 1;

    DECLARE @collection_method_id INT = (
        SELECT TOP 1 collection_method_id FROM grac_practice.collection_method_master
        WHERE is_active = 1 AND (collection_method_code = N'Manual' OR collection_method_name = N'Manual')
        ORDER BY collection_method_id);
    IF @collection_method_id IS NULL
        SELECT TOP 1 @collection_method_id = collection_method_id
        FROM grac_practice.collection_method_master WHERE is_active = 1
        ORDER BY display_order, collection_method_id;
    IF @collection_method_id IS NULL
        THROW 52610, 'sp_resolve_evidence_reconcile_for_instance: collection method master data is missing.', 1;

    DECLARE @inherited_alignment_id INT = (
        SELECT TOP 1 alignment_status_id FROM grac_practice.evidence_alignment_status_master
        WHERE is_active = 1 AND alignment_status_code = N'Inherited'
        ORDER BY alignment_status_id);
    IF @inherited_alignment_id IS NULL
        SELECT TOP 1 @inherited_alignment_id = alignment_status_id
        FROM grac_practice.evidence_alignment_status_master WHERE is_active = 1
        ORDER BY display_order, alignment_status_id;
    IF @inherited_alignment_id IS NULL
        THROW 52611, 'sp_resolve_evidence_reconcile_for_instance: evidence alignment status master data is missing.', 1;

    -- The driving set. This is the ONLY difference from the block that used
    -- to live in sp_resolve_obligation_adopt: there it came from the call's
    -- JSON payload (@req WHERE IsAdopted = 1), here it is what the instance
    -- has actually adopted.
    --
    -- obligation_id > 0 keeps organization-defined obligations out: their
    -- evidence is matched on source_practice_instance_obligation_id
    -- (migrations 231/232), not through the repository view below.
    DECLARE @adopted TABLE (ObligationId BIGINT PRIMARY KEY);

    INSERT INTO @adopted (ObligationId)
    SELECT DISTINCT pio.obligation_id
    FROM   grac_practice.practice_instance_obligation pio
    WHERE  pio.practice_instance_id = @practice_instance_id
      AND  pio.status = N'Active'
      AND  pio.obligation_id > 0;

    IF NOT EXISTS (SELECT 1 FROM @adopted) RETURN;

    UPDATE pie
       SET source_obligation_id = x.ObligationId,
           updated_by           = @actor,
           updated_dt           = SYSUTCDATETIME()
    FROM   grac_practice.practice_instance_evidence pie
    CROSS  APPLY (
        SELECT TOP 1 r.ObligationId
        FROM   @adopted r
        JOIN   grac_practice.vw_pm_obligation_evidence oe ON oe.organization_id = @organization_id AND oe.obligation_id = r.ObligationId
        JOIN   GRAC_New.evidence_type_master get ON get.evidence_type_id = oe.evidence_type_id
        JOIN   grac_practice.evidence_type_master pet
               ON pet.evidence_type_name = get.evidence_type_name AND pet.is_active = 1
        WHERE  get.evidence_type_id = pie.evidence_type_id
        ORDER  BY r.ObligationId
    ) x
    WHERE  pie.practice_instance_id = @practice_instance_id
      AND  pie.status = N'Active'
      AND  pie.source_obligation_id IS NULL;

    INSERT grac_practice.practice_instance_evidence
        (organization_id, practice_instance_id, evidence_type_id,
         inherited_from_repository, organization_modified, is_mandatory,
         collection_method_id, collection_frequency_id, retention_period,
         alignment_status_id, source_obligation_id, source_obligation_evidence_id,
         status, record_status_id, entered_by)
    SELECT @organization_id, @practice_instance_id, s.evidence_type_id,
           1, 0, 1,
           @collection_method_id, NULL, s.retention_requirement,
           @inherited_alignment_id, s.ObligationId, s.obligation_evidence_id,
           N'Active', @active_record_status_id, @actor
    FROM (
        SELECT r.ObligationId,
               get.evidence_type_id,
               MIN(oe.obligation_evidence_id) AS obligation_evidence_id,
               MIN(oe.retention_requirement)  AS retention_requirement
        FROM   @adopted r
        JOIN   grac_practice.vw_pm_obligation_evidence oe ON oe.organization_id = @organization_id AND oe.obligation_id = r.ObligationId
        JOIN   GRAC_New.evidence_type_master get ON get.evidence_type_id = oe.evidence_type_id
        JOIN   grac_practice.evidence_type_master pet
               ON pet.evidence_type_name = get.evidence_type_name AND pet.is_active = 1
        GROUP  BY r.ObligationId, get.evidence_type_id
    ) s
    WHERE NOT EXISTS (SELECT 1 FROM grac_practice.practice_instance_evidence x
                       WHERE x.practice_instance_id = @practice_instance_id
                         AND x.evidence_type_id     = s.evidence_type_id
                         AND x.source_obligation_id = s.ObligationId
                         AND x.status = N'Active');
END
GO

PRINT '399 complete.';
GO
