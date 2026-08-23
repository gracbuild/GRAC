-- =====================================================================
-- 144 Resolve -- read an obligation's evidence the way admin publishes it
--
-- THE DEFECT
-- ----------
-- 141 read an obligation's evidence as
--     GRAC_New.requirement_obligation_evidence WHERE obligation_id = X
-- which is only the DIRECT attachments. Since the 7-type taxonomy landed
-- (Control Management 026-029), evidence also attaches through six
-- per-type link tables:
--     obligation_state_evidence_link          obligation_execution_evidence_link
--     obligation_assurance_evidence_link      obligation_event_response_evidence_link
--     obligation_constraint_evidence_link     obligation_retention_evidence_link
-- Migration 122 unions both sources; 141 did not. So an obligation whose
-- evidence is attached through a link table -- an Assurance obligation,
-- for one -- reported no published evidence, created no rows on adoption,
-- and the workspace said "No evidence is published for this obligation"
-- while the practice page listed it plainly.
--
-- THE SECOND DEFECT
-- -----------------
-- The insert skipped a type the instance already had, whatever produced
-- it. An instance carrying evidence added by hand on the Practice
-- Instance form would silently get nothing on adoption, and that hand-
-- added row -- source_obligation_id NULL -- belonged to no obligation, so
-- the workspace could not show it either. It is now attached to the
-- obligation instead of being skipped, and the guard is per obligation.
--
-- Re-emits sp_resolve_obligation_list and sp_resolve_obligation_adopt,
-- and backfills the attachment for evidence that already exists.
--
-- Error codes are unchanged from 141 (52604-52612): these are the same
-- procedures, corrected.
-- Depends on 140, 141. Rollback: 144_..._rollback.sql re-emits 141's.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.sp_resolve_obligation_adopt','P') IS NULL
BEGIN
    RAISERROR('144: sp_resolve_obligation_adopt is missing. Run 141 first.', 16, 1);
    SET NOEXEC ON;
END
GO

IF OBJECT_ID('GRAC_New.obligation_assurance_evidence_link','U') IS NULL
BEGIN
    RAISERROR('144: the obligation evidence link tables are missing. Run Control Management 026-029 first.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- A view for "every evidence this obligation publishes", direct or
-- linked. One definition, used by the list and by the adopt, so the count
-- on the card can never disagree with the rows adoption creates -- which
-- is exactly what went wrong when the two read different things.
-- =====================================================================
CREATE OR ALTER VIEW grac_practice.vw_pm_obligation_evidence
AS
    SELECT roe.obligation_id,
           roe.obligation_evidence_id,
           roe.evidence_type_id,
           roe.retention_requirement,
           N'Direct' AS Source
    FROM   GRAC_New.requirement_obligation_evidence roe
    UNION
    SELECT l.obligation_id,
           roe.obligation_evidence_id,
           roe.evidence_type_id,
           roe.retention_requirement,
           N'Link' AS Source
    FROM (
        SELECT obligation_id, obligation_evidence_id, status FROM GRAC_New.obligation_state_evidence_link
        UNION ALL SELECT obligation_id, obligation_evidence_id, status FROM GRAC_New.obligation_execution_evidence_link
        UNION ALL SELECT obligation_id, obligation_evidence_id, status FROM GRAC_New.obligation_assurance_evidence_link
        UNION ALL SELECT obligation_id, obligation_evidence_id, status FROM GRAC_New.obligation_event_response_evidence_link
        UNION ALL SELECT obligation_id, obligation_evidence_id, status FROM GRAC_New.obligation_constraint_evidence_link
        UNION ALL SELECT obligation_id, obligation_evidence_id, status FROM GRAC_New.obligation_retention_evidence_link
    ) l
    JOIN   GRAC_New.requirement_obligation_evidence roe
           ON roe.obligation_evidence_id = l.obligation_evidence_id
    WHERE  l.status = N'Active';
GO

-- =====================================================================
-- sp_resolve_obligation_list -- only the evidence count changes
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_resolve_obligation_list
    @practice_instance_id BIGINT,
    @include_unsubscribed BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    IF @practice_instance_id IS NULL
        THROW 52604, 'sp_resolve_obligation_list: practice_instance_id is required.', 1;

    DECLARE @organization_id BIGINT, @practice_id BIGINT;
    SELECT @organization_id = organization_id, @practice_id = practice_id
    FROM   grac_practice.practice_instance
    WHERE  practice_instance_id = @practice_instance_id;

    IF @organization_id IS NULL
        THROW 52605, 'sp_resolve_obligation_list: instance not found.', 1;

    ;WITH reachable AS (
        SELECT orm.obligation_id,
               orm.release_id,
               CAST(CASE WHEN EXISTS (SELECT 1 FROM grac_practice.repository_subscription s
                                       WHERE s.organization_id = @organization_id
                                         AND s.release_id = orm.release_id
                                         AND s.status = N'Active')
                         THEN 1 ELSE 0 END AS BIT) AS is_subscribed
        FROM   grac_practice.practice pp
        JOIN   grac_practice.organization_requirement req
               ON req.organization_requirement_id = pp.organization_requirement_id
        LEFT   JOIN GRAC_New.requirement repo_req
               ON repo_req.requirement_code = req.requirement_code AND repo_req.status = N'Active'
        JOIN   GRAC_New.obligation_requirement_release_map orm
               ON orm.requirement_id = COALESCE(req.repository_requirement_id, repo_req.requirement_id)
              AND orm.status = N'Active'
        WHERE  pp.practice_id = @practice_id
    ),
    picked AS (
        SELECT obligation_id,
               MIN(release_id)                 AS release_id,
               MAX(CAST(is_subscribed AS INT)) AS is_subscribed
        FROM   reachable
        WHERE  @include_unsubscribed = 1 OR is_subscribed = 1
        GROUP  BY obligation_id
    )
    SELECT
        o.obligation_id                 AS ObligationId,
        COALESCE(NULLIF(LTRIM(RTRIM(o.obligation_name)), N''),
                 LEFT(o.obligation_text, 300))          AS ObligationName,
        o.obligation_text               AS ObligationText,
        t.type_code                     AS TypeCode,
        t.type_name                     AS TypeName,
        pk.release_id                   AS ReleaseId,
        COALESCE(a.artifact_code + N' ' + r.version_no,
                 a.artifact_name + N' ' + r.version_no,
                 r.version_no)          AS FrameworkRelease,
        CAST(pk.is_subscribed AS BIT)   AS IsSubscribed,

        COALESCE(exec_freq.option_label, o.frequency_type) AS PublishedExecutionFrequency,
        o.responsibility                AS PublishedResponsibility,
        o.approval_authority            AS PublishedApprovalAuthority,
        o.retention_requirement         AS PublishedRetention,

        adopt.practice_instance_obligation_id AS AdoptionId,
        CAST(CASE WHEN adopt.practice_instance_obligation_id IS NULL THEN 0 ELSE 1 END AS BIT) AS IsAdopted,
        adopt.organization_modified     AS OrganizationModified,
        adopt.execution_frequency_id    AS ExecutionFrequencyId,
        adopt.execution_frequency       AS ExecutionFrequency,
        adopt.assurance_frequency_id    AS AssuranceFrequencyId,
        adopt.assurance_frequency       AS AssuranceFrequency,
        adopt.responsibility            AS Responsibility,
        adopt.approval_authority        AS ApprovalAuthority,
        adopt.retention_period          AS RetentionPeriod,
        adopt.remarks                   AS Remarks,
        adopt.adopted_by                AS AdoptedBy,
        adopt.adopted_dt                AS AdoptedDt,

        ev.PublishedEvidenceCount       AS PublishedEvidenceCount,
        ev.ResolvedEvidenceCount        AS ResolvedEvidenceCount
    FROM   picked pk
    JOIN   GRAC_New.requirement_obligation o
           ON o.obligation_id = pk.obligation_id AND o.status = N'Active'
    LEFT   JOIN GRAC_New.obligation_type_master t
           ON t.obligation_type_id = o.obligation_type_id
    LEFT   JOIN GRAC_New.reference_option exec_freq
           ON exec_freq.reference_option_id = o.execution_frequency_id
    LEFT   JOIN GRAC_New.release r ON r.release_id = pk.release_id
    LEFT   JOIN GRAC_New.artifact a ON a.artifact_id = r.artifact_id
    LEFT   JOIN grac_practice.practice_instance_obligation adopt
           ON adopt.practice_instance_id = @practice_instance_id
          AND adopt.obligation_id        = pk.obligation_id
          AND adopt.status               = N'Active'
    OUTER  APPLY (
        -- Direct AND linked, so the count matches what adoption creates.
        SELECT COUNT(DISTINCT oe.evidence_type_id) AS PublishedEvidenceCount,
               (SELECT COUNT(*) FROM grac_practice.practice_instance_evidence pie
                 WHERE pie.practice_instance_id = @practice_instance_id
                   AND pie.source_obligation_id = pk.obligation_id
                   AND pie.status = N'Active') AS ResolvedEvidenceCount
        FROM   grac_practice.vw_pm_obligation_evidence oe
        WHERE  oe.obligation_id = pk.obligation_id
    ) ev
    ORDER  BY ISNULL(t.display_order, 999),
              COALESCE(o.obligation_name, o.obligation_text);
END
GO

-- =====================================================================
-- sp_resolve_obligation_adopt -- evidence section corrected
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_resolve_obligation_adopt
    @practice_instance_id BIGINT,
    @payload_json         NVARCHAR(MAX),
    @actor                NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @practice_instance_id IS NULL
        THROW 52606, 'sp_resolve_obligation_adopt: practice_instance_id is required.', 1;
    IF @payload_json IS NULL OR ISJSON(@payload_json) <> 1
        THROW 52607, 'sp_resolve_obligation_adopt: payload must be a JSON array.', 1;

    DECLARE @organization_id BIGINT;
    SELECT @organization_id = organization_id
    FROM   grac_practice.practice_instance
    WHERE  practice_instance_id = @practice_instance_id;

    IF @organization_id IS NULL
        THROW 52608, 'sp_resolve_obligation_adopt: instance not found.', 1;

    DECLARE @active_record_status_id INT = (
        SELECT TOP 1 record_status_id FROM grac_practice.record_status_master
        WHERE status_code = 'ACTIVE' OR status_name = 'Active' ORDER BY record_status_id);
    IF @active_record_status_id IS NULL
        THROW 52609, 'sp_resolve_obligation_adopt: record status master data is missing.', 1;

    DECLARE @collection_method_id INT = (
        SELECT TOP 1 collection_method_id FROM grac_practice.collection_method_master
        WHERE is_active = 1 AND (collection_method_code = N'Manual' OR collection_method_name = N'Manual')
        ORDER BY collection_method_id);
    IF @collection_method_id IS NULL
        SELECT TOP 1 @collection_method_id = collection_method_id
        FROM grac_practice.collection_method_master WHERE is_active = 1
        ORDER BY display_order, collection_method_id;
    IF @collection_method_id IS NULL
        THROW 52610, 'sp_resolve_obligation_adopt: collection method master data is missing.', 1;

    DECLARE @inherited_alignment_id INT = (
        SELECT TOP 1 alignment_status_id FROM grac_practice.evidence_alignment_status_master
        WHERE is_active = 1 AND alignment_status_code = N'Inherited'
        ORDER BY alignment_status_id);
    IF @inherited_alignment_id IS NULL
        SELECT TOP 1 @inherited_alignment_id = alignment_status_id
        FROM grac_practice.evidence_alignment_status_master WHERE is_active = 1
        ORDER BY display_order, alignment_status_id;
    IF @inherited_alignment_id IS NULL
        THROW 52611, 'sp_resolve_obligation_adopt: evidence alignment status master data is missing.', 1;

    DECLARE @req TABLE (
        ObligationId          BIGINT PRIMARY KEY,
        IsAdopted             BIT,
        ExecutionFrequencyId  INT NULL,
        ExecutionFrequency    NVARCHAR(120) NULL,
        AssuranceFrequencyId  INT NULL,
        AssuranceFrequency    NVARCHAR(120) NULL,
        Responsibility        NVARCHAR(300) NULL,
        ApprovalAuthority     NVARCHAR(300) NULL,
        RetentionPeriod       NVARCHAR(120) NULL,
        Remarks               NVARCHAR(MAX) NULL,
        PubExecutionFrequency NVARCHAR(120) NULL,
        PubResponsibility     NVARCHAR(300) NULL,
        PubApprovalAuthority  NVARCHAR(300) NULL,
        PubRetention          NVARCHAR(120) NULL,
        ObligationName        NVARCHAR(500) NULL,
        ObligationTypeCode    NVARCHAR(60)  NULL,
        ReleaseId             BIGINT NULL,
        IsModified            BIT NULL
    );

    INSERT INTO @req (ObligationId, IsAdopted, ExecutionFrequencyId, ExecutionFrequency,
                      AssuranceFrequencyId, AssuranceFrequency, Responsibility,
                      ApprovalAuthority, RetentionPeriod, Remarks)
    SELECT j.ObligationId,
           ISNULL(j.IsAdopted, 0),
           j.ExecutionFrequencyId, NULLIF(LTRIM(RTRIM(j.ExecutionFrequency)), N''),
           j.AssuranceFrequencyId, NULLIF(LTRIM(RTRIM(j.AssuranceFrequency)), N''),
           NULLIF(LTRIM(RTRIM(j.Responsibility)), N''),
           NULLIF(LTRIM(RTRIM(j.ApprovalAuthority)), N''),
           NULLIF(LTRIM(RTRIM(j.RetentionPeriod)), N''),
           NULLIF(LTRIM(RTRIM(j.Remarks)), N'')
    FROM OPENJSON(@payload_json) WITH (
        ObligationId         BIGINT        '$.obligationId',
        IsAdopted            BIT           '$.isAdopted',
        ExecutionFrequencyId INT           '$.executionFrequencyId',
        ExecutionFrequency   NVARCHAR(120) '$.executionFrequency',
        AssuranceFrequencyId INT           '$.assuranceFrequencyId',
        AssuranceFrequency   NVARCHAR(120) '$.assuranceFrequency',
        Responsibility       NVARCHAR(300) '$.responsibility',
        ApprovalAuthority    NVARCHAR(300) '$.approvalAuthority',
        RetentionPeriod      NVARCHAR(120) '$.retentionPeriod',
        Remarks              NVARCHAR(MAX) '$.remarks'
    ) j
    WHERE j.ObligationId IS NOT NULL;

    IF NOT EXISTS (SELECT 1 FROM @req)
        THROW 52612, 'sp_resolve_obligation_adopt: no obligations were supplied.', 1;

    UPDATE r
       SET PubExecutionFrequency = COALESCE(ef.option_label, o.frequency_type),
           PubResponsibility     = o.responsibility,
           PubApprovalAuthority  = o.approval_authority,
           PubRetention          = o.retention_requirement,
           ObligationName        = COALESCE(NULLIF(LTRIM(RTRIM(o.obligation_name)), N''),
                                            LEFT(o.obligation_text, 300)),
           ObligationTypeCode    = t.type_code
    FROM  @req r
    JOIN  GRAC_New.requirement_obligation o ON o.obligation_id = r.ObligationId
    LEFT  JOIN GRAC_New.obligation_type_master t ON t.obligation_type_id = o.obligation_type_id
    LEFT  JOIN GRAC_New.reference_option ef ON ef.reference_option_id = o.execution_frequency_id;

    UPDATE r
       SET ReleaseId = x.release_id
    FROM  @req r
    CROSS APPLY (
        SELECT MIN(orm.release_id) AS release_id
        FROM   GRAC_New.obligation_requirement_release_map orm
        WHERE  orm.obligation_id = r.ObligationId
          AND  orm.status = N'Active'
          AND  EXISTS (SELECT 1 FROM grac_practice.repository_subscription s
                        WHERE s.organization_id = @organization_id
                          AND s.release_id = orm.release_id
                          AND s.status = N'Active')
    ) x;

    UPDATE @req
       SET IsModified = CASE
             WHEN (ExecutionFrequency  IS NOT NULL AND ISNULL(ExecutionFrequency, N'')  <> ISNULL(PubExecutionFrequency, N''))
               OR (ExecutionFrequencyId IS NOT NULL)
               OR (AssuranceFrequency  IS NOT NULL) OR (AssuranceFrequencyId IS NOT NULL)
               OR (Responsibility      IS NOT NULL AND ISNULL(Responsibility, N'')      <> ISNULL(PubResponsibility, N''))
               OR (ApprovalAuthority   IS NOT NULL AND ISNULL(ApprovalAuthority, N'')   <> ISNULL(PubApprovalAuthority, N''))
               OR (RetentionPeriod     IS NOT NULL AND ISNULL(RetentionPeriod, N'')     <> ISNULL(PubRetention, N''))
               OR (Remarks             IS NOT NULL)
             THEN 1 ELSE 0 END;

    BEGIN TRAN;

    MERGE grac_practice.practice_instance_obligation AS target
    USING (SELECT * FROM @req WHERE IsAdopted = 1) AS src
       ON target.practice_instance_id = @practice_instance_id
      AND target.obligation_id        = src.ObligationId
    WHEN MATCHED THEN UPDATE SET
        organization_modified  = src.IsModified,
        execution_frequency_id = src.ExecutionFrequencyId,
        execution_frequency    = COALESCE(src.ExecutionFrequency, src.PubExecutionFrequency),
        assurance_frequency_id = src.AssuranceFrequencyId,
        assurance_frequency    = src.AssuranceFrequency,
        responsibility         = COALESCE(src.Responsibility,    src.PubResponsibility),
        approval_authority     = COALESCE(src.ApprovalAuthority, src.PubApprovalAuthority),
        retention_period       = COALESCE(src.RetentionPeriod,   src.PubRetention),
        remarks                = src.Remarks,
        obligation_name        = src.ObligationName,
        obligation_type_code   = src.ObligationTypeCode,
        release_id             = COALESCE(src.ReleaseId, target.release_id),
        status                 = N'Active',
        record_status_id       = @active_record_status_id,
        updated_by             = @actor,
        updated_dt             = SYSUTCDATETIME()
    WHEN NOT MATCHED THEN INSERT
        (organization_id, practice_instance_id, obligation_id, release_id,
         obligation_name, obligation_type_code,
         inherited_from_repository, organization_modified,
         execution_frequency_id, execution_frequency,
         assurance_frequency_id, assurance_frequency,
         responsibility, approval_authority, retention_period, remarks,
         adopted_by, adopted_dt, status, record_status_id, entered_by)
    VALUES
        (@organization_id, @practice_instance_id, src.ObligationId, src.ReleaseId,
         src.ObligationName, src.ObligationTypeCode,
         1, src.IsModified,
         src.ExecutionFrequencyId, COALESCE(src.ExecutionFrequency, src.PubExecutionFrequency),
         src.AssuranceFrequencyId, src.AssuranceFrequency,
         COALESCE(src.Responsibility,    src.PubResponsibility),
         COALESCE(src.ApprovalAuthority, src.PubApprovalAuthority),
         COALESCE(src.RetentionPeriod,   src.PubRetention),
         src.Remarks,
         @actor, SYSUTCDATETIME(), N'Active', @active_record_status_id, @actor);

    UPDATE pio
       SET status     = N'Retired',
           updated_by = @actor,
           updated_dt = SYSUTCDATETIME()
    FROM  grac_practice.practice_instance_obligation pio
    JOIN  @req r ON r.ObligationId = pio.obligation_id
    WHERE pio.practice_instance_id = @practice_instance_id
      AND r.IsAdopted = 0
      AND pio.status = N'Active';

    UPDATE pie
       SET status     = N'Retired',
           updated_by = @actor,
           updated_dt = SYSUTCDATETIME()
    FROM  grac_practice.practice_instance_evidence pie
    JOIN  @req r ON r.ObligationId = pie.source_obligation_id
    WHERE pie.practice_instance_id = @practice_instance_id
      AND r.IsAdopted = 0
      AND pie.status = N'Active'
      AND pie.organization_modified = 0
      AND NULLIF(LTRIM(RTRIM(ISNULL(pie.evidence_location, N''))), N'') IS NULL
      AND NULLIF(LTRIM(RTRIM(ISNULL(pie.evidence_locator,  N''))), N'') IS NULL
      AND NULLIF(LTRIM(RTRIM(ISNULL(pie.evidence_owner,    N''))), N'') IS NULL;

    -- ---------------- evidence ----------------
    -- 1. Adopt an existing UNATTACHED row of the right type rather than
    --    skipping it. Somebody added it by hand on the Practice Instance
    --    form; it is the same evidence, and leaving it unattached made it
    --    invisible in this workspace.
    UPDATE pie
       SET source_obligation_id = x.ObligationId,
           updated_by           = @actor,
           updated_dt           = SYSUTCDATETIME()
    FROM   grac_practice.practice_instance_evidence pie
    CROSS  APPLY (
        SELECT TOP 1 r.ObligationId
        FROM   @req r
        JOIN   grac_practice.vw_pm_obligation_evidence oe ON oe.obligation_id = r.ObligationId
        JOIN   GRAC_New.evidence_type_master get ON get.evidence_type_id = oe.evidence_type_id
        JOIN   grac_practice.evidence_type_master pet
               ON pet.evidence_type_name = get.evidence_type_name AND pet.is_active = 1
        WHERE  r.IsAdopted = 1
          AND  pet.evidence_type_id = pie.evidence_type_id
        -- Deterministic when two adopted obligations publish the same
        -- type: the lowest id wins, so a reload does not reshuffle it.
        ORDER  BY r.ObligationId
    ) x
    WHERE  pie.practice_instance_id = @practice_instance_id
      AND  pie.status = N'Active'
      AND  pie.source_obligation_id IS NULL;

    -- 2. Create what is still missing. The guard is now per obligation:
    --    two obligations publishing the same evidence type each get their
    --    own row, because each has to be resolved on its own terms.
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
               pet.evidence_type_id,
               MIN(oe.obligation_evidence_id) AS obligation_evidence_id,
               MIN(oe.retention_requirement)  AS retention_requirement
        FROM   @req r
        JOIN   grac_practice.vw_pm_obligation_evidence oe ON oe.obligation_id = r.ObligationId
        JOIN   GRAC_New.evidence_type_master get ON get.evidence_type_id = oe.evidence_type_id
        JOIN   grac_practice.evidence_type_master pet
               ON pet.evidence_type_name = get.evidence_type_name AND pet.is_active = 1
        WHERE  r.IsAdopted = 1
        GROUP  BY r.ObligationId, pet.evidence_type_id
    ) s
    WHERE NOT EXISTS (SELECT 1 FROM grac_practice.practice_instance_evidence x
                       WHERE x.practice_instance_id = @practice_instance_id
                         AND x.evidence_type_id     = s.evidence_type_id
                         AND x.source_obligation_id = s.ObligationId
                         AND x.status = N'Active');

    COMMIT TRAN;

    SELECT r.ObligationId   AS ObligationId,
           r.ObligationName AS ObligationName,
           CASE WHEN r.IsAdopted = 1 THEN N'Adopted' ELSE N'Removed' END AS Outcome,
           r.IsModified     AS OrganizationModified,
           CASE WHEN r.IsAdopted = 1 AND r.ReleaseId IS NULL THEN CAST(1 AS BIT)
                ELSE CAST(0 AS BIT) END AS NotSubscribed,
           (SELECT COUNT(*) FROM grac_practice.practice_instance_evidence pie
             WHERE pie.practice_instance_id = @practice_instance_id
               AND pie.source_obligation_id = r.ObligationId
               AND pie.status = N'Active') AS EvidenceRows,
           (SELECT COUNT(DISTINCT oe.evidence_type_id)
              FROM grac_practice.vw_pm_obligation_evidence oe
              JOIN GRAC_New.evidence_type_master get ON get.evidence_type_id = oe.evidence_type_id
             WHERE oe.obligation_id = r.ObligationId
               AND NOT EXISTS (SELECT 1 FROM grac_practice.evidence_type_master pet
                                WHERE pet.evidence_type_name = get.evidence_type_name
                                  AND pet.is_active = 1)) AS UnmappedEvidenceTypes
    FROM   @req r
    ORDER  BY r.ObligationName;
END
GO

-- =====================================================================
-- Backfill: attach evidence that already exists.
--
-- Obligations adopted before this migration created no rows for their
-- linked evidence, and any hand-added row is unattached. This pass fixes
-- what it can from the current state; it creates nothing, so an adopted
-- obligation whose rows were never created still needs a re-save on the
-- screen -- the report below says which.
-- =====================================================================
UPDATE pie
   SET source_obligation_id = x.obligation_id,
       updated_by           = 'seed-144',
       updated_dt           = SYSUTCDATETIME()
FROM   grac_practice.practice_instance_evidence pie
CROSS  APPLY (
    SELECT TOP 1 pio.obligation_id
    FROM   grac_practice.practice_instance_obligation pio
    JOIN   grac_practice.vw_pm_obligation_evidence oe ON oe.obligation_id = pio.obligation_id
    JOIN   GRAC_New.evidence_type_master get ON get.evidence_type_id = oe.evidence_type_id
    JOIN   grac_practice.evidence_type_master pet
           ON pet.evidence_type_name = get.evidence_type_name AND pet.is_active = 1
    WHERE  pio.practice_instance_id = pie.practice_instance_id
      AND  pio.status = N'Active'
      AND  pet.evidence_type_id = pie.evidence_type_id
    ORDER  BY pio.obligation_id
) x
WHERE  pie.status = N'Active'
  AND  pie.source_obligation_id IS NULL;
GO

-- =====================================================================
-- Sanity report
-- =====================================================================
SELECT 'obligation evidence view created' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.vw_pm_obligation_evidence','V') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL SELECT 'list and adopt re-emitted',
       CASE WHEN OBJECT_ID('grac_practice.sp_resolve_obligation_list','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_resolve_obligation_adopt','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT 'adopt reads the view, not the direct table alone',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_resolve_obligation_adopt'))
                 LIKE '%vw_pm_obligation_evidence%'
            THEN 'PASS' ELSE 'FAIL' END;

-- How much evidence each obligation publishes, direct versus linked.
-- A row with Direct = 0 and Linked > 0 is exactly the case that was
-- invisible before this migration.
SELECT oe.obligation_id AS ObligationId,
       SUM(CASE WHEN oe.Source = N'Direct' THEN 1 ELSE 0 END) AS DirectEvidence,
       SUM(CASE WHEN oe.Source = N'Link'   THEN 1 ELSE 0 END) AS LinkedEvidence
FROM   grac_practice.vw_pm_obligation_evidence oe
GROUP  BY oe.obligation_id
HAVING SUM(CASE WHEN oe.Source = N'Link' THEN 1 ELSE 0 END) > 0
ORDER  BY oe.obligation_id;

-- Adopted obligations that publish evidence but have no rows here yet.
-- Open the instance and press Save on the obligation to create them.
SELECT pio.practice_instance_id AS PracticeInstanceId,
       pi.instance_code         AS InstanceCode,
       pio.obligation_id        AS ObligationId,
       pio.obligation_name      AS ObligationName,
       (SELECT COUNT(DISTINCT oe.evidence_type_id)
          FROM grac_practice.vw_pm_obligation_evidence oe
         WHERE oe.obligation_id = pio.obligation_id) AS PublishedEvidenceTypes
FROM   grac_practice.practice_instance_obligation pio
JOIN   grac_practice.practice_instance pi ON pi.practice_instance_id = pio.practice_instance_id
WHERE  pio.status = N'Active'
  AND  EXISTS (SELECT 1 FROM grac_practice.vw_pm_obligation_evidence oe
                WHERE oe.obligation_id = pio.obligation_id)
  AND  NOT EXISTS (SELECT 1 FROM grac_practice.practice_instance_evidence pie
                    WHERE pie.practice_instance_id = pio.practice_instance_id
                      AND pie.source_obligation_id = pio.obligation_id
                      AND pie.status = N'Active')
ORDER  BY pio.practice_instance_id, pio.obligation_id;

PRINT '144 Obligation evidence now reads direct and linked attachments.';
PRINT 'Anything listed above is adopted but has no evidence rows yet --';
PRINT 'open the instance and press Save on that obligation to create them.';
GO
