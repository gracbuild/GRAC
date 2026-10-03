-- =====================================================================
-- 400 Adopt every published evidence type (drop the local-master filter)
--
-- FIXES: after 399 stopped the FK error, adopting/saving an obligation
--   still dropped one (or more) evidence rows -- a published evidence type
--   that exists in the SHARED catalogue GRAC_New.evidence_type_master but
--   has no active same-name row in the LOCAL grac_practice.evidence_type_master
--   was silently filtered out and never created.
--
-- CAUSE: sp_resolve_evidence_reconcile_for_instance still INNER JOINed the
--   local master (pet) in both the source_obligation_id back-fill and the
--   evidence INSERT. That join was only ever there to translate the shared
--   id to the local id; 399 made the procedure store the shared id, so the
--   join now serves no purpose except to exclude published evidence types
--   the local master happens not to list.
--
-- FIX: re-issue sp_resolve_evidence_reconcile_for_instance (live body from
--   399, logic otherwise unchanged) with the local-master (pet) join removed
--   from both the CROSS APPLY back-fill and the INSERT. Evidence is now
--   driven purely by the org-scoped published set
--   (vw_pm_obligation_evidence joined to GRAC_New.evidence_type_master),
--   which is the authoritative catalogue after the 397/399 standardization,
--   so every published evidence type for an adopted obligation is created
--   with its shared, FK-valid evidence_type_id.
--
-- SCOPE: procedure body only. No schema or data change.
-- DEPENDS ON: 399 (current proc body), 002 (fk_pm_evidence_shared_type).
-- Rollback: 400_..._rollback.sql re-issues the 399 body (pet filter back).
-- Re-runnable: yes (CREATE OR ALTER). ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID('GRAC_New.evidence_type_master','U') IS NULL
   THROW 52730, '400 requires GRAC_New.evidence_type_master.', 1;
IF COL_LENGTH('grac_practice.practice_instance_evidence','evidence_type_id') IS NULL
   THROW 52730, '400 requires grac_practice.practice_instance_evidence.evidence_type_id.', 1;
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
        GROUP  BY r.ObligationId, get.evidence_type_id
    ) s
    WHERE NOT EXISTS (SELECT 1 FROM grac_practice.practice_instance_evidence x
                       WHERE x.practice_instance_id = @practice_instance_id
                         AND x.evidence_type_id     = s.evidence_type_id
                         AND x.source_obligation_id = s.ObligationId
                         AND x.status = N'Active');
END
GO

PRINT '400 complete.';
GO
