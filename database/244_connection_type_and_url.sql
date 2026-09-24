-- =====================================================================
-- 244 Connection type + URL for Automated assurance
--
-- WHAT AND WHY
-- ------------
-- An operator adopting an Assurance obligation whose assurance_type is
-- Automated needs somewhere to say HOW the automation reaches the
-- system under test. Today the field is just "Manual or Automated";
-- when the answer is Automated, the row silently loses the two things
-- the runtime needs to actually run: what kind of connection to use
-- (API today, SDK / DB / SSH later), and where to point it.
--
-- This migration:
--   1. Creates a small connection_type_master lookup, seeded with one
--      row (API) so the dropdown is not empty. Additional connection
--      types (SDK, JDBC, SSH, ...) are added by inserting into the
--      table -- no code change required, which is what the user asked
--      for ("vere add cheyyanam enkil table lu add cheytha mathiyallo").
--   2. Adds two nullable columns to practice_instance_obligation:
--        connection_type_id  INT           FK -> connection_type_master
--        connection_url      NVARCHAR(500)
--      Both stay NULL unless the obligation has assurance_type =
--      Automated. Storing them here rather than on a side table means
--      the value travels with the obligation the operator is editing
--      and one save writes them together with assurance_type.
--   3. Re-emits the three procedures the Resolve workspace uses
--      (sp_resolve_obligation_adopt, sp_resolve_obligation_list,
--       sp_resolve_local_obligation_save) so they accept and project
--      the new columns. Bodies come from the 242 emission -- 242 is
--      the current head for all three -- and the only edits are the
--      column plumbing at the same COALESCE / MERGE points 242 uses
--      for implementation_status_id.
--
-- HISTORY
-- -------
-- Adoption / listing procs last emitted in 242. Local-save also 242.
--
-- SAFE TO RE-RUN. Requires 242.
-- ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    PRINT 'ABORT (244): schema grac_practice missing.';
    SET NOEXEC ON;
END
GO

IF OBJECT_ID('grac_practice.practice_instance_obligation','U') IS NULL
BEGIN
    PRINT 'ABORT (244): practice_instance_obligation missing (run 140 first).';
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. connection_type_master
-- =====================================================================
IF OBJECT_ID('grac_practice.connection_type_master','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.connection_type_master (
        connection_type_id   INT IDENTITY(1,1) NOT NULL
            CONSTRAINT pk_pm_connection_type PRIMARY KEY,
        connection_type_code NVARCHAR(40)  NOT NULL
            CONSTRAINT uq_pm_connection_type_code UNIQUE,
        connection_type_name NVARCHAR(120) NOT NULL,
        description          NVARCHAR(400) NULL,
        display_order        INT           NOT NULL CONSTRAINT df_pm_connection_type_display DEFAULT (100),
        is_active            BIT           NOT NULL CONSTRAINT df_pm_connection_type_active  DEFAULT (1),
        entered_by           NVARCHAR(100) NULL,
        entered_dt           DATETIME2(3)  NOT NULL CONSTRAINT df_pm_connection_type_entered DEFAULT (SYSUTCDATETIME()),
        updated_by           NVARCHAR(100) NULL,
        updated_dt           DATETIME2(3)  NULL
    );
    PRINT '244: connection_type_master created.';
END
GO

-- Idempotent seed. Only API for now; more codes (SDK, JDBC, SSH, ...)
-- are inserted into this table -- no proc / UI change required.
;WITH src AS (
    SELECT * FROM (VALUES
        (N'API', N'API',  N'REST or SOAP HTTP endpoint the runtime calls to check assurance.', 10)
    ) v(code, name_, description_, display_order)
)
MERGE grac_practice.connection_type_master AS t
USING src AS s
   ON t.connection_type_code = s.code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (connection_type_code, connection_type_name, description, display_order, is_active, entered_by)
    VALUES (s.code, s.name_, s.description_, s.display_order, 1, 'seed-244')
WHEN MATCHED AND (t.connection_type_name <> s.name_ OR ISNULL(t.description, N'') <> s.description_ OR t.display_order <> s.display_order OR t.is_active = 0) THEN
    UPDATE SET connection_type_name = s.name_,
               description          = s.description_,
               display_order        = s.display_order,
               is_active            = 1,
               updated_by           = 'seed-244',
               updated_dt           = SYSUTCDATETIME();
GO

-- =====================================================================
-- 2. Column additions on practice_instance_obligation
-- =====================================================================
IF COL_LENGTH('grac_practice.practice_instance_obligation','connection_type_id') IS NULL
BEGIN
    ALTER TABLE grac_practice.practice_instance_obligation
        ADD connection_type_id INT NULL
            CONSTRAINT fk_pm_pio_connection_type
                REFERENCES grac_practice.connection_type_master(connection_type_id);
    PRINT '244: practice_instance_obligation.connection_type_id added.';
END
GO

IF COL_LENGTH('grac_practice.practice_instance_obligation','connection_url') IS NULL
BEGIN
    ALTER TABLE grac_practice.practice_instance_obligation
        ADD connection_url NVARCHAR(500) NULL;
    PRINT '244: practice_instance_obligation.connection_url added.';
END
GO

-- =====================================================================
-- 3. sp_resolve_obligation_adopt -- 242 body + connection columns
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
        AssuranceType         NVARCHAR(40)  NULL,
        Remarks               NVARCHAR(MAX) NULL,
        EventTypeId           BIGINT        NULL,
        SlaValue              INT           NULL,
        SlaUnit               NVARCHAR(20)  NULL,
        ImplementationStatusId INT          NULL,
        -- Migration 244: Automated-only connection payload. Absent keys
        -- stay NULL (COALESCE below preserves whatever is stored) so a
        -- caller who does not touch these fields does not blank them.
        ConnectionTypeId      INT           NULL,
        ConnectionUrl         NVARCHAR(500) NULL,
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
                      ApprovalAuthority, RetentionPeriod, AssuranceType, Remarks,
                      EventTypeId, SlaValue, SlaUnit, ImplementationStatusId,
                      ConnectionTypeId, ConnectionUrl)
    SELECT j.ObligationId,
           ISNULL(j.IsAdopted, 0),
           j.ExecutionFrequencyId, NULLIF(LTRIM(RTRIM(j.ExecutionFrequency)), N''),
           j.AssuranceFrequencyId, NULLIF(LTRIM(RTRIM(j.AssuranceFrequency)), N''),
           NULLIF(LTRIM(RTRIM(j.Responsibility)), N''),
           NULLIF(LTRIM(RTRIM(j.ApprovalAuthority)), N''),
           NULLIF(LTRIM(RTRIM(j.RetentionPeriod)), N''),
           NULLIF(LTRIM(RTRIM(j.AssuranceType)), N''),
           NULLIF(LTRIM(RTRIM(j.Remarks)), N''),
           j.EventTypeId,
           j.SlaValue,
           NULLIF(LTRIM(RTRIM(j.SlaUnit)), N''),
           j.ImplementationStatusId,
           j.ConnectionTypeId,
           NULLIF(LTRIM(RTRIM(j.ConnectionUrl)), N'')
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
        AssuranceType        NVARCHAR(40)  '$.assuranceType',
        Remarks              NVARCHAR(MAX) '$.remarks',
        EventTypeId          BIGINT        '$.eventTypeId',
        SlaValue             INT           '$.slaValue',
        SlaUnit              NVARCHAR(20)  '$.slaUnit',
        ImplementationStatusId INT         '$.implementationStatusId',
        ConnectionTypeId     INT           '$.connectionTypeId',
        ConnectionUrl        NVARCHAR(500) '$.connectionUrl'
    ) j
    WHERE j.ObligationId IS NOT NULL;

    IF NOT EXISTS (SELECT 1 FROM @req)
        THROW 52612, 'sp_resolve_obligation_adopt: no obligations were supplied.', 1;

    -- Reject a connection_type_id that does not exist, so a stale UI
    -- cache never writes a broken FK. NULL is fine (Manual assurance,
    -- or user simply hasn't picked one yet).
    IF EXISTS (SELECT 1 FROM @req r
                WHERE r.ConnectionTypeId IS NOT NULL
                  AND NOT EXISTS (SELECT 1 FROM grac_practice.connection_type_master c
                                   WHERE c.connection_type_id = r.ConnectionTypeId
                                     AND c.is_active = 1))
        THROW 52675, 'sp_resolve_obligation_adopt: unknown connection type.', 1;

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
               OR (AssuranceType       IS NOT NULL)
               OR (Remarks             IS NOT NULL)
               OR (EventTypeId         IS NOT NULL)
               OR (SlaValue            IS NOT NULL)
               OR (SlaUnit             IS NOT NULL)
               OR (ImplementationStatusId IS NOT NULL)
               -- Migration 244: connection info is always an
               -- organisation-side answer (nothing is published), so any
               -- value here flips the row to modified.
               OR (ConnectionTypeId    IS NOT NULL)
               OR (ConnectionUrl       IS NOT NULL)
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
        assurance_type         = COALESCE(src.AssuranceType, target.assurance_type),
        remarks                = src.Remarks,
        event_type_id          = COALESCE(src.EventTypeId, target.event_type_id),
        sla_value              = COALESCE(src.SlaValue,    target.sla_value),
        sla_unit               = COALESCE(src.SlaUnit,     target.sla_unit),
        implementation_status_id = COALESCE(src.ImplementationStatusId, target.implementation_status_id),
        -- Migration 244: same "absent means keep what's stored" contract
        -- the other overrides use. When the operator switches assurance
        -- to Manual the UI will send NULL for both, which keeps the last
        -- known values; if that becomes wrong later we surface a
        -- "Clear" action that sends an explicit empty string / 0.
        connection_type_id     = COALESCE(src.ConnectionTypeId, target.connection_type_id),
        connection_url         = COALESCE(src.ConnectionUrl,    target.connection_url),
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
         responsibility, approval_authority, retention_period, assurance_type, remarks,
         event_type_id, sla_value, sla_unit, implementation_status_id,
         connection_type_id, connection_url,
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
         src.AssuranceType,
         src.Remarks,
         src.EventTypeId, src.SlaValue, src.SlaUnit, src.ImplementationStatusId,
         src.ConnectionTypeId, src.ConnectionUrl,
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

    -- evidence: adopt-unattached + insert-missing (unchanged from 242)
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
PRINT '244: sp_resolve_obligation_adopt accepts connection_type_id + connection_url.';
GO

-- =====================================================================
-- 4. sp_resolve_obligation_list -- projects ConnectionTypeId + ConnectionUrl
--
-- Body identical to 242 EXCEPT for the two new columns in each of the
-- two SELECT halves. Column count / order still matches the UNION halves.
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
    SELECT * FROM (
    SELECT
        o.obligation_id                 AS ObligationId,
        CAST(0 AS BIT)                  AS IsOrganizationDefined,
        N'p' + CAST(o.obligation_id AS NVARCHAR(20)) AS RowKey,
        ISNULL(t.display_order, 999)    AS SortOrder,
        COALESCE(NULLIF(LTRIM(RTRIM(o.obligation_name)), N''),
                 LEFT(o.obligation_text, 300))          AS ObligationName,
        o.obligation_text               AS ObligationText,
        o.obligation_text               AS ObligationDescription,
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

        COALESCE(td.StateRulesJson,      N'[]') AS StateRulesJson,
        COALESCE(td.ExecutionSpecsJson,  N'[]') AS ExecutionSpecsJson,
        COALESCE(td.AssuranceSpecsJson,  N'[]') AS AssuranceSpecsJson,
        COALESCE(td.EventResponsesJson,  N'[]') AS EventResponsesJson,
        COALESCE(td.ConstraintRulesJson, N'[]') AS ConstraintRulesJson,
        COALESCE(td.RetentionSpecsJson,  N'[]') AS RetentionSpecsJson,
        COALESCE(td.EvidenceJson,        N'[]') AS PublishedEvidenceJson,

        adopt.practice_instance_obligation_id AS AdoptionId,
        CAST(CASE WHEN adopt.practice_instance_obligation_id IS NULL THEN 0 ELSE 1 END AS BIT) AS IsAdopted,
        adopt.organization_modified     AS OrganizationModified,
        adopt.execution_frequency_id    AS ExecutionFrequencyId,
        adopt.execution_frequency       AS ExecutionFrequency,
        adopt.assurance_frequency_id    AS AssuranceFrequencyId,
        adopt.assurance_frequency       AS AssuranceFrequency,
        adopt.event_type_id             AS EventTypeId,
        adopt.sla_value                 AS SlaValue,
        adopt.sla_unit                  AS SlaUnit,
        adopt.implementation_status_id  AS ImplementationStatusId,
        -- Migration 244: connection payload for Automated assurance.
        -- Null on any obligation that has not been configured yet.
        adopt.connection_type_id        AS ConnectionTypeId,
        adopt.connection_url            AS ConnectionUrl,
        adopt.responsibility            AS Responsibility,
        adopt.approval_authority        AS ApprovalAuthority,
        adopt.retention_period          AS RetentionPeriod,
        adopt.assurance_type            AS AdoptedAssuranceType,
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
    LEFT   JOIN grac_practice.vw_pm_obligation_typed_detail td
           ON td.ObligationId = pk.obligation_id
    LEFT   JOIN grac_practice.practice_instance_obligation adopt
           ON adopt.practice_instance_id = @practice_instance_id
          AND adopt.obligation_id        = pk.obligation_id
          AND adopt.status               = N'Active'
    OUTER  APPLY (
        SELECT COUNT(DISTINCT oe.evidence_type_id) AS PublishedEvidenceCount,
               (SELECT COUNT(*) FROM grac_practice.practice_instance_evidence pie
                 WHERE pie.practice_instance_id = @practice_instance_id
                   AND pie.source_obligation_id = pk.obligation_id
                   AND pie.status = N'Active') AS ResolvedEvidenceCount
        FROM   grac_practice.vw_pm_obligation_evidence oe
        WHERE  oe.obligation_id = pk.obligation_id
    ) ev

    UNION ALL
    SELECT
        CAST(NULL AS BIGINT)            AS ObligationId,
        CAST(1 AS BIT)                  AS IsOrganizationDefined,
        N'l' + CAST(pio.practice_instance_obligation_id AS NVARCHAR(20)) AS RowKey,
        1000 + CAST(pio.practice_instance_obligation_id % 1000 AS INT) AS SortOrder,
        pio.obligation_name             AS ObligationName,
        pio.obligation_description      AS ObligationText,
        pio.obligation_description      AS ObligationDescription,
        pio.obligation_type_code        AS TypeCode,
        lt.type_name                    AS TypeName,
        CAST(NULL AS BIGINT)            AS ReleaseId,
        CAST(NULL AS NVARCHAR(400))     AS FrameworkRelease,
        CAST(1 AS BIT)                  AS IsSubscribed,

        CAST(NULL AS NVARCHAR(200))     AS PublishedExecutionFrequency,
        CAST(NULL AS NVARCHAR(300))     AS PublishedResponsibility,
        CAST(NULL AS NVARCHAR(300))     AS PublishedApprovalAuthority,
        CAST(NULL AS NVARCHAR(200))     AS PublishedRetention,

        CASE WHEN pio.obligation_type_code = N'State'         THEN ISNULL(pio.typed_detail_json, N'[]') ELSE N'[]' END AS StateRulesJson,
        CASE WHEN pio.obligation_type_code = N'Execution'     THEN ISNULL(pio.typed_detail_json, N'[]') ELSE N'[]' END AS ExecutionSpecsJson,
        CASE WHEN pio.obligation_type_code = N'Assurance'     THEN ISNULL(pio.typed_detail_json, N'[]') ELSE N'[]' END AS AssuranceSpecsJson,
        CASE WHEN pio.obligation_type_code = N'EventResponse' THEN ISNULL(pio.typed_detail_json, N'[]') ELSE N'[]' END AS EventResponsesJson,
        CASE WHEN pio.obligation_type_code = N'Constraint'    THEN ISNULL(pio.typed_detail_json, N'[]') ELSE N'[]' END AS ConstraintRulesJson,
        CASE WHEN pio.obligation_type_code = N'Retention'     THEN ISNULL(pio.typed_detail_json, N'[]') ELSE N'[]' END AS RetentionSpecsJson,
        CASE WHEN pio.obligation_type_code = N'Evidence'      THEN ISNULL(pio.typed_detail_json, N'[]') ELSE N'[]' END AS PublishedEvidenceJson,

        pio.practice_instance_obligation_id AS AdoptionId,
        CAST(1 AS BIT)                  AS IsAdopted,
        CAST(1 AS BIT)                  AS OrganizationModified,
        pio.execution_frequency_id      AS ExecutionFrequencyId,
        pio.execution_frequency         AS ExecutionFrequency,
        pio.assurance_frequency_id      AS AssuranceFrequencyId,
        pio.assurance_frequency         AS AssuranceFrequency,
        pio.event_type_id               AS EventTypeId,
        pio.sla_value                   AS SlaValue,
        pio.sla_unit                    AS SlaUnit,
        pio.implementation_status_id    AS ImplementationStatusId,
        -- Migration 244: mirrors the top half.
        pio.connection_type_id          AS ConnectionTypeId,
        pio.connection_url              AS ConnectionUrl,
        pio.responsibility              AS Responsibility,
        pio.approval_authority          AS ApprovalAuthority,
        pio.retention_period            AS RetentionPeriod,
        pio.assurance_type              AS AdoptedAssuranceType,
        pio.remarks                     AS Remarks,
        pio.adopted_by                  AS AdoptedBy,
        pio.adopted_dt                  AS AdoptedDt,

        0                               AS PublishedEvidenceCount,
        (SELECT COUNT(*) FROM grac_practice.practice_instance_evidence pie2
          WHERE pie2.practice_instance_id = @practice_instance_id
            AND pie2.source_practice_instance_obligation_id = pio.practice_instance_obligation_id
            AND pie2.status = N'Active')  AS ResolvedEvidenceCount
    FROM   grac_practice.practice_instance_obligation pio
    LEFT   JOIN GRAC_New.obligation_type_master lt
           ON lt.type_code = pio.obligation_type_code
    WHERE  pio.practice_instance_id = @practice_instance_id
      AND  pio.obligation_id IS NULL
      AND  pio.status = N'Active'
    ) x
    ORDER  BY x.SortOrder, x.ObligationName;
END
GO
PRINT '244: sp_resolve_obligation_list projects ConnectionTypeId + ConnectionUrl.';
GO

-- =====================================================================
-- 5. sp_resolve_local_obligation_save -- accepts the two new fields
--
-- Body identical to 242 EXCEPT for the two new parameters and their
-- placement in INSERT + UPDATE column lists.
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
    @implementation_status_id        INT           = NULL,
    -- Migration 244: Automated-only connection payload.
    @connection_type_id              INT           = NULL,
    @connection_url                  NVARCHAR(500) = NULL,
    @remarks                         NVARCHAR(MAX) = NULL,
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

    IF @is_admin = 0 AND ISNULL(@owner_id, -1) <> ISNULL(@caller_employee_id, -2)
        THROW 52693, 'sp_resolve_local_obligation_save: this practice instance belongs to another owner.', 1;

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

    -- Migration 244: reject a stale connection_type_id, exactly as the
    -- adopt proc does. NULL is fine.
    IF @connection_type_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM grac_practice.connection_type_master
                        WHERE connection_type_id = @connection_type_id AND is_active = 1)
        THROW 52676, 'sp_resolve_local_obligation_save: unknown connection type.', 1;

    SET @connection_url = NULLIF(LTRIM(RTRIM(@connection_url)), N'');

    DECLARE @active_record_status_id INT = (
        SELECT TOP 1 record_status_id FROM grac_practice.record_status_master
        WHERE status_code = N'ACTIVE' OR status_name = N'Active' ORDER BY record_status_id);

    DECLARE @ev_added INT = 0, @ev_removed INT = 0, @ev_kept INT = 0;

    IF ISNULL(@practice_instance_obligation_id, 0) = 0
    BEGIN
        INSERT grac_practice.practice_instance_obligation
            (organization_id, practice_instance_id, obligation_id, release_id,
             obligation_name, obligation_description, obligation_type_code,
             typed_detail_json,
             inherited_from_repository, organization_modified,
             execution_frequency_id, execution_frequency,
             responsibility, approval_authority, assurance_type, remarks,
             implementation_status_id,
             connection_type_id, connection_url,
             adopted_by, adopted_dt, status, record_status_id, entered_by)
        VALUES
            (@organization_id, @practice_instance_id, NULL, NULL,
             @obligation_name, @obligation_description, @obligation_type_code,
             ISNULL(@typed_detail_json, N'[]'),
             0, 1,
             @execution_frequency_id, @execution_frequency,
             @responsibility, @approval_authority, @assurance_type, @remarks,
             @implementation_status_id,
             @connection_type_id, @connection_url,
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
           implementation_status_id = COALESCE(@implementation_status_id, implementation_status_id),
           -- Migration 244: same "absent means keep" contract as the
           -- adopt proc uses for its overrides.
           connection_type_id     = COALESCE(@connection_type_id, connection_type_id),
           connection_url         = COALESCE(@connection_url,     connection_url),
           status                 = N'Active',
           updated_by             = @actor,
           updated_dt             = SYSUTCDATETIME()
     WHERE practice_instance_obligation_id = @practice_instance_obligation_id
       AND practice_instance_id            = @practice_instance_id
       AND obligation_id IS NULL;

    IF @@ROWCOUNT = 0
        THROW 52700, 'sp_resolve_local_obligation_save: no organisation-defined obligation with that id on this instance.', 1;

    EXEC grac_practice.sp_resolve_local_obligation_evidence_sync
         @practice_instance_id            = @practice_instance_id,
         @practice_instance_obligation_id = @practice_instance_obligation_id,
         @evidence_json                   = @evidence_json,
         @actor                           = @actor,
         @evidence_added                  = @ev_added   OUTPUT,
         @evidence_removed                = @ev_removed OUTPUT,
         @evidence_kept                   = @ev_kept    OUTPUT;

    SELECT CAST(1 AS BIT) AS Success, N'Obligation updated.' AS Message,
           @practice_instance_obligation_id AS PracticeInstanceObligationId,
           @ev_added AS EvidenceAdded, @ev_removed AS EvidenceRemoved, @ev_kept AS EvidenceKept;
END
GO
PRINT '244: sp_resolve_local_obligation_save accepts connection_type_id + connection_url.';
GO

-- =====================================================================
-- 6. sp_get_connection_type_lookup -- read-side shim
--
-- Same 7-parameter shape as sp_get_asset_taxonomy_lookup (241) so the
-- generic query path in ResolveProcedureAsync can invoke it with the
-- same argument list. Returns the small connection_type_master set;
-- the operationalize UI shows it in a Connection Type dropdown whenever
-- assurance_type is Automated. Additional connection types are added
-- by inserting new rows into connection_type_master -- no code change.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_get_connection_type_lookup
    @p_entity_type   NVARCHAR(100) = N'',
    @p_action        NVARCHAR(40)  = N'',
    @p_id            BIGINT        = 0,
    @p_search        NVARCHAR(250) = N'',
    @p_status        NVARCHAR(30)  = N'',
    @p_payload       NVARCHAR(MAX) = N'{}',
    @p_usr_id        NVARCHAR(200) = N'system'
AS
BEGIN
    SET NOCOUNT ON;

    -- Same shape master lookups use elsewhere: EntityType is fixed to
    -- 'connection-types' so a client can key the response the same way it
    -- keys the /lookups payload.
    SELECT N'connection-types'                          AS EntityType,
           CAST(connection_type_id AS NVARCHAR(40))     AS Value,
           connection_type_name                         AS Label,
           connection_type_code                         AS Code,
           display_order                                AS DisplayOrder,
           description                                  AS Description
    FROM   grac_practice.connection_type_master
    WHERE  is_active = 1
    ORDER  BY display_order, connection_type_id;
END
GO
PRINT '244: sp_get_connection_type_lookup ready.';
GO

-- =====================================================================
-- Verification
-- =====================================================================
PRINT '=== 244 verification ===';

SELECT '244-a connection_type_master present' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.connection_type_master','U') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '244-b API seed present',
       CASE WHEN EXISTS (SELECT 1 FROM grac_practice.connection_type_master
                          WHERE connection_type_code = N'API' AND is_active = 1) THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '244-c connection_type_id column added',
       CASE WHEN COL_LENGTH('grac_practice.practice_instance_obligation','connection_type_id') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '244-d connection_url column added',
       CASE WHEN COL_LENGTH('grac_practice.practice_instance_obligation','connection_url') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '244-e adopt proc references connection columns',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_resolve_obligation_adopt','P')) LIKE '%connection_type_id%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_resolve_obligation_adopt','P')) LIKE '%connection_url%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '244-f list proc projects ConnectionTypeId',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_resolve_obligation_list','P')) LIKE '%ConnectionTypeId%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_resolve_obligation_list','P')) LIKE '%ConnectionUrl%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '244-g local-save proc accepts @connection_type_id',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_resolve_local_obligation_save','P')) LIKE '%@connection_type_id%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_resolve_local_obligation_save','P')) LIKE '%@connection_url%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '244-h connection-type lookup shim present',
       CASE WHEN OBJECT_ID('grac_practice.sp_get_connection_type_lookup','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
-- Regression guard: 242's implementation status plumbing must still be
-- in place on all three procedures.
SELECT '244-i regression: implementation_status_id still plumbed',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_resolve_obligation_adopt','P'))       LIKE '%implementation_status_id%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_resolve_obligation_list','P'))        LIKE '%ImplementationStatusId%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_resolve_local_obligation_save','P'))  LIKE '%@implementation_status_id%'
            THEN 'PASS' ELSE 'FAIL' END;

PRINT '';
PRINT '244 complete. Connection type + URL are live on the Resolve obligation card.';
GO

SET NOEXEC OFF;
GO
