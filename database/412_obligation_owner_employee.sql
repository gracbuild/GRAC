-- =====================================================================
-- 412 Obligation Owner is an EMPLOYEE (Functional User), not a role
--
-- WHAT AND WHY
-- ------------
-- On Operationalize (Resolve workspace) and in the organisation-defined
-- obligation form, an obligation's Owner was picked from Role Master and
-- stored as the role NAME in `responsibility`. The Owner is now an
-- EMPLOYEE, and only a Functional User (organization_employee
-- .is_functional_user = 1, 341) -- the same rule the Practice Instance
-- Owner picker follows (342).
--
-- MODEL
--   * practice_instance_obligation.owner_employee_id  NEW (FK employee)
--   * practice_obligation.owner_employee_id           NEW (FK employee)
--   * `responsibility` stays, now holding the owner EMPLOYEE's name,
--     written by the save procedures from the employee record. Every
--     reader that shows the owner (Practice View, View Obligations,
--     calendar/scheduler "owner" fallback, Resolve cards) already reads
--     `responsibility`, so they show the employee with no change.
--
-- WRITE CONTRACT (all three save paths)
--   owner id NULL / absent -> owner left as stored (older callers)
--   owner id 0             -> owner cleared (id and name)
--   owner id > 0           -> must be an Active Functional User of the
--                             obligation's organization, else refused
--                             (52733 Resolve, 57214 practice level);
--                             the name is taken from the employee.
--
-- NOT CHANGED
--   * Existing rows keep their stored role name as text (the screens
--     still show it) with owner_employee_id NULL until an employee is
--     picked. No role -> employee guessing.
--   * Approval authority (hidden on the screens) stays a role.
--   * Nothing in the database resolved an obligation's owner role to a
--     person (tasks, schedules and event checklists are assigned from the
--     instance owner / schedule owner / applicability owner role), so no
--     assignment query needed repointing.
--
-- Procedures re-issued (latest bodies, 412 changes marked "412"):
--   sp_resolve_obligation_adopt      (394)  + ownerEmployeeId in the JSON rows
--   sp_resolve_obligation_list       (396)  + OwnerEmployeeId
--   sp_resolve_local_obligation_save (340)  + @owner_employee_id
--   sp_practice_obligation_fan_out   (340)  copies owner_employee_id
--   sp_practice_obligation_save      (340)  + @owner_employee_id
--   sp_practice_obligation_list      (340)  + OwnerEmployeeId
--
-- Re-runnable. ASCII only. Depends on 341 (is_functional_user), 340,
-- 394, 396. Restart the API after running.
-- Rollback: 412_obligation_owner_employee_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF COL_LENGTH('grac_practice.organization_employee','is_functional_user') IS NULL
BEGIN
    PRINT 'ABORT (412): organization_employee.is_functional_user missing (run 341 first).';
    SET NOEXEC ON;
END
GO

-- The re-issued bodies read these; guard them rather than let a CREATE
-- fail half way (Msg 207 would still let the script print "applied").
IF OBJECT_ID('grac_practice.sp_resolve_obligation_adopt','P') IS NULL
   OR OBJECT_ID('grac_practice.sp_practice_obligation_fan_out','P') IS NULL
   OR OBJECT_ID('grac_practice.fn_org_requirement_obligation','IF') IS NULL
   OR COL_LENGTH('grac_practice.practice_instance_obligation','event_type_id') IS NULL
   OR COL_LENGTH('grac_practice.practice_instance_obligation','source_practice_obligation_id') IS NULL
   OR COL_LENGTH('grac_practice.practice_obligation','event_type_id') IS NULL
BEGIN
    PRINT 'ABORT (412): run 340, 394 and 396 first.';
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 0. owner_employee_id columns
-- =====================================================================
IF COL_LENGTH('grac_practice.practice_instance_obligation','owner_employee_id') IS NULL
    ALTER TABLE grac_practice.practice_instance_obligation
        ADD owner_employee_id BIGINT NULL
            CONSTRAINT fk_pm_pio_owner_employee
            REFERENCES grac_practice.organization_employee(employee_id);
GO
IF COL_LENGTH('grac_practice.practice_obligation','owner_employee_id') IS NULL
    ALTER TABLE grac_practice.practice_obligation
        ADD owner_employee_id BIGINT NULL
            CONSTRAINT fk_pm_po_owner_employee
            REFERENCES grac_practice.organization_employee(employee_id);
GO

-- =====================================================================
-- 1. sp_resolve_obligation_adopt (394 body + OwnerEmployeeId)
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
        -- 412: the owner EMPLOYEE (absent = keep, 0 = clear, > 0 = set).
        OwnerEmployeeId       BIGINT        NULL,
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
                      ConnectionTypeId, ConnectionUrl, OwnerEmployeeId)
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
           NULLIF(LTRIM(RTRIM(j.ConnectionUrl)), N''),
           j.OwnerEmployeeId
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
        ConnectionUrl        NVARCHAR(500) '$.connectionUrl',
        OwnerEmployeeId      BIGINT        '$.ownerEmployeeId'
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

    -- 412: the Owner is an EMPLOYEE (a Functional User of this
    -- organization), no longer a role name. responsibility keeps the
    -- display name every reader already shows, taken from the employee.
    IF EXISTS (SELECT 1 FROM @req r
                WHERE r.OwnerEmployeeId > 0
                  AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee e
                                   WHERE e.employee_id        = r.OwnerEmployeeId
                                     AND e.organization_id    = @organization_id
                                     AND e.status             = N'Active'
                                     AND e.is_functional_user = 1))
        THROW 52733, 'The obligation owner must be an active Functional User of this organization.', 1;

    UPDATE r
       SET Responsibility = e.employee_name
    FROM  @req r
    JOIN  grac_practice.organization_employee e ON e.employee_id = r.OwnerEmployeeId
    WHERE r.OwnerEmployeeId > 0;

    UPDATE r
       SET PubExecutionFrequency = COALESCE(ef.option_label, o.frequency_type),
           PubResponsibility     = o.responsibility,
           PubApprovalAuthority  = o.approval_authority,
           PubRetention          = o.retention_requirement,
           ObligationName        = COALESCE(NULLIF(LTRIM(RTRIM(o.obligation_name)), N''),
                                            LEFT(o.obligation_text, 300)),
           ObligationTypeCode    = t.type_code
    FROM  @req r
    JOIN  grac_practice.fn_org_requirement_obligation(@organization_id) o ON o.obligation_id = r.ObligationId
    LEFT  JOIN GRAC_New.obligation_type_master t ON t.obligation_type_id = o.obligation_type_id
    LEFT  JOIN GRAC_New.reference_option ef ON ef.reference_option_id = o.execution_frequency_id;

    UPDATE r
       SET ReleaseId = x.release_id
    FROM  @req r
    CROSS APPLY (
        SELECT MIN(orm.release_id) AS release_id
        FROM   grac_practice.fn_org_obligation_requirement_release_map(@organization_id) orm
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
        -- 412: clearing the owner (0) clears the name too, rather than
        -- falling back to the published text.
        responsibility         = CASE WHEN src.OwnerEmployeeId = 0 THEN NULL
                                      ELSE COALESCE(src.Responsibility, src.PubResponsibility) END,
        owner_employee_id      = CASE WHEN src.OwnerEmployeeId IS NULL THEN target.owner_employee_id
                                      ELSE NULLIF(src.OwnerEmployeeId, 0) END,
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
         responsibility, owner_employee_id, approval_authority, retention_period, assurance_type, remarks,
         event_type_id, sla_value, sla_unit, implementation_status_id,
         connection_type_id, connection_url,
         adopted_by, adopted_dt, status, record_status_id, entered_by)
    VALUES
        (@organization_id, @practice_instance_id, src.ObligationId, src.ReleaseId,
         src.ObligationName, src.ObligationTypeCode,
         1, src.IsModified,
         src.ExecutionFrequencyId, COALESCE(src.ExecutionFrequency, src.PubExecutionFrequency),
         src.AssuranceFrequencyId, src.AssuranceFrequency,
         CASE WHEN src.OwnerEmployeeId = 0 THEN NULL
              ELSE COALESCE(src.Responsibility, src.PubResponsibility) END,
         NULLIF(src.OwnerEmployeeId, 0),
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

    -- evidence: extracted to
    -- grac_practice.sp_resolve_evidence_reconcile_for_instance by migration
    -- 304, and called here rather than held twice. The procedure drives off
    -- the adoption TABLE, which this procedure has already written above, so
    -- the set it sees is what @req just made true -- plus any obligation
    -- adopted on an earlier call whose evidence was never created.
    --
    -- It returns no result set, so a plain EXEC is safe inside this
    -- transaction: nothing reaches the caller and nothing blocks the
    -- ROLLBACK that XACT_ABORT may need.
    EXEC grac_practice.sp_resolve_evidence_reconcile_for_instance
         @practice_instance_id = @practice_instance_id,
         @actor                = @actor;

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
             WHERE oe.organization_id = @organization_id
               AND oe.obligation_id = r.ObligationId
               AND NOT EXISTS (SELECT 1 FROM grac_practice.evidence_type_master pet
                                WHERE pet.evidence_type_name = get.evidence_type_name
                                  AND pet.is_active = 1)) AS UnmappedEvidenceTypes
    FROM   @req r
    ORDER  BY r.ObligationName;
END
GO

-- =====================================================================
-- 2. sp_resolve_obligation_list (396 body + OwnerEmployeeId)
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
        LEFT   JOIN grac_practice.fn_org_requirement(@organization_id) repo_req
               ON repo_req.requirement_code = req.requirement_code AND repo_req.status = N'Active'
        JOIN   grac_practice.fn_org_obligation_requirement_release_map(@organization_id) orm
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
        -- 412: the owner employee behind Responsibility (NULL on a row
        -- still carrying a legacy role name, or not yet set).
        adopt.owner_employee_id         AS OwnerEmployeeId,
        adopt.approval_authority        AS ApprovalAuthority,
        adopt.retention_period          AS RetentionPeriod,
        adopt.assurance_type            AS AdoptedAssuranceType,
        adopt.remarks                   AS Remarks,
        adopt.adopted_by                AS AdoptedBy,
        adopt.adopted_dt                AS AdoptedDt,

        ev.PublishedEvidenceCount       AS PublishedEvidenceCount,
        ev.ResolvedEvidenceCount        AS ResolvedEvidenceCount,
        -- 396: 'Retired' once a repository retirement of this obligation
        -- has been approved (flag only -- the card stays, with a badge).
        o.lifecycle_status              AS RepositoryLifecycleStatus
    FROM   picked pk
    JOIN   grac_practice.fn_org_requirement_obligation(@organization_id) o
           ON o.obligation_id = pk.obligation_id AND o.status = N'Active'
    LEFT   JOIN GRAC_New.obligation_type_master t
           ON t.obligation_type_id = o.obligation_type_id
    LEFT   JOIN GRAC_New.reference_option exec_freq
           ON exec_freq.reference_option_id = o.execution_frequency_id
    LEFT   JOIN GRAC_New.release r ON r.release_id = pk.release_id
    LEFT   JOIN GRAC_New.artifact a ON a.artifact_id = r.artifact_id
    LEFT   JOIN grac_practice.vw_pm_org_obligation_typed_detail td
           ON td.OrganizationId = @organization_id
          AND td.ObligationId = pk.obligation_id
    LEFT   JOIN grac_practice.practice_instance_obligation adopt
           ON adopt.practice_instance_id = @practice_instance_id
          AND adopt.obligation_id        = pk.obligation_id
          AND adopt.status               = N'Active'
    OUTER  APPLY (
        SELECT COUNT(DISTINCT oe.evidence_type_id) AS PublishedEvidenceCount,
               (SELECT COUNT(*) FROM grac_practice.practice_instance_evidence pie
                 WHERE pie.practice_instance_id = @practice_instance_id
                   AND pie.source_obligation_id = pk.obligation_id
                   AND pie.status = N'Active'
                   -- 353: an evidence row counts as RESOLVED only once its
                   -- location AND locator are both filled (same test as
                   -- sp_resolve_evidence_list.IsResolved). Before this it
                   -- counted every row that merely EXISTS, so an empty
                   -- evidence row created by the single obligation+evidence
                   -- save turned the obligation green with no details entered.
                   AND NULLIF(LTRIM(RTRIM(ISNULL(pie.evidence_location, N''))), N'') IS NOT NULL
                   AND NULLIF(LTRIM(RTRIM(ISNULL(pie.evidence_locator,  N''))), N'') IS NOT NULL) AS ResolvedEvidenceCount
        FROM   grac_practice.vw_pm_obligation_evidence oe
        WHERE  oe.organization_id = @organization_id
          AND  oe.obligation_id = pk.obligation_id
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
        pio.owner_employee_id           AS OwnerEmployeeId,
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
            AND pie2.status = N'Active'
            -- 353: resolved = location AND locator both filled (see fix above).
            AND NULLIF(LTRIM(RTRIM(ISNULL(pie2.evidence_location, N''))), N'') IS NOT NULL
            AND NULLIF(LTRIM(RTRIM(ISNULL(pie2.evidence_locator,  N''))), N'') IS NOT NULL)  AS ResolvedEvidenceCount,
        CAST(NULL AS NVARCHAR(20))      AS RepositoryLifecycleStatus
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

-- =====================================================================
-- 3. sp_resolve_local_obligation_save (340 body + @owner_employee_id)
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
    -- 412: owner employee (NULL keep / 0 clear / > 0 set).
    @owner_employee_id               BIGINT        = NULL,
    @approval_authority              NVARCHAR(300) = NULL,
    @assurance_type                  NVARCHAR(40)  = NULL,
    @implementation_status_id        INT           = NULL,
    -- Migration 340: which event makes this obligation due. NULL means
    -- not event-driven, the same "absent has no opinion, NULL is a real
    -- answer" reading @assurance_type already gets.
    @event_type_id                   BIGINT        = NULL,
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

    -- Migration 340: reject a stale event_type_id, the same existence
    -- check sp_resolve_obligation_adopt already applies via its JSON
    -- payload (234). NULL is fine -- it means "not event-driven".
    IF @event_type_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM GRAC_New.event_type_master
                        WHERE event_type_id = @event_type_id)
        THROW 52706, 'sp_resolve_local_obligation_save: unknown event type.', 1;

    -- 412: the Owner is an EMPLOYEE (a Functional User of this
    -- organization), no longer a role name. @owner_employee_id:
    --   NULL = leave the stored owner as it is (older callers),
    --   0    = clear the owner,
    --   > 0  = set it; responsibility (the display name every reader
    --          already shows) is written from the employee record.
    IF @owner_employee_id > 0
    BEGIN
        DECLARE @owner_name NVARCHAR(300) = (
            SELECT e.employee_name
            FROM   grac_practice.organization_employee e
            WHERE  e.employee_id        = @owner_employee_id
              AND  e.organization_id    = @organization_id
              AND  e.status             = N'Active'
              AND  e.is_functional_user = 1);
        IF @owner_name IS NULL
            THROW 52733, 'The obligation owner must be an active Functional User of this organization.', 1;
        SET @responsibility = @owner_name;
    END
    ELSE IF @owner_employee_id = 0
        SET @responsibility = NULL;

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
             responsibility, owner_employee_id, approval_authority, assurance_type, remarks,
             implementation_status_id,
             event_type_id,
             connection_type_id, connection_url,
             adopted_by, adopted_dt, status, record_status_id, entered_by)
        VALUES
            (@organization_id, @practice_instance_id, NULL, NULL,
             @obligation_name, @obligation_description, @obligation_type_code,
             ISNULL(@typed_detail_json, N'[]'),
             0, 1,
             @execution_frequency_id, @execution_frequency,
             @responsibility, NULLIF(@owner_employee_id, 0), @approval_authority, @assurance_type, @remarks,
             @implementation_status_id,
             @event_type_id,
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
           owner_employee_id      = CASE WHEN @owner_employee_id IS NULL THEN owner_employee_id
                                         ELSE NULLIF(@owner_employee_id, 0) END,   -- 412
           approval_authority     = @approval_authority,
           assurance_type         = @assurance_type,
           remarks                = @remarks,
           implementation_status_id = COALESCE(@implementation_status_id, implementation_status_id),
           -- Migration 340: direct write, same contract as assurance_type
           -- above -- the edit form resends the whole payload, so absent
           -- really does mean "not event-driven any more".
           event_type_id          = @event_type_id,
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

-- =====================================================================
-- 4. sp_practice_obligation_fan_out (340 body, copies owner_employee_id)
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
        evidence_json          NVARCHAR(MAX) NULL,
        event_type_id          BIGINT NULL    -- Migration 340
    );

    INSERT @defs (practice_obligation_id, is_active, evidence_json, event_type_id)
    SELECT po.practice_obligation_id,
           CASE WHEN po.status = N'Active' THEN 1 ELSE 0 END,
           po.evidence_json,
           po.event_type_id
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
    --     Migration 340: event_type_id joins that set.
    --
    --     Instance-owned parameters are NOT touched: assurance_frequency,
    --     the 234 ADOPT-only sla_value / sla_unit override, implementation
    --     status, connection info and the adoption stamp all stay as the
    --     instance left them. A copy that had been retired comes back
    --     Active rather than being duplicated beside itself.
    UPDATE pio
       SET obligation_name        = po.obligation_name,
           obligation_description = po.obligation_description,
           obligation_type_code   = po.obligation_type_code,
           typed_detail_json      = ISNULL(po.typed_detail_json, N'[]'),
           execution_frequency_id = po.execution_frequency_id,
           execution_frequency    = po.execution_frequency,
           responsibility         = po.responsibility,
           owner_employee_id      = po.owner_employee_id,   -- 412
           approval_authority     = po.approval_authority,
           assurance_type         = po.assurance_type,
           remarks                = po.remarks,
           event_type_id          = po.event_type_id,
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
         responsibility, owner_employee_id, approval_authority, assurance_type, remarks,
         event_type_id,
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
           po.responsibility, po.owner_employee_id, po.approval_authority, po.assurance_type, po.remarks,
           po.event_type_id,
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

-- =====================================================================
-- 5. sp_practice_obligation_save (340 body + @owner_employee_id)
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
    -- 412: owner employee (NULL keep / 0 clear / > 0 set).
    @owner_employee_id      BIGINT        = NULL,
    @approval_authority     NVARCHAR(300) = NULL,
    @assurance_type         NVARCHAR(40)  = NULL,
    -- Migration 340: which event makes every fanned-out copy of this
    -- definition due. NULL means not event-driven. Same field, same
    -- meaning as sp_resolve_local_obligation_save's -- this is just the
    -- practice-level door onto it.
    @event_type_id          BIGINT        = NULL,
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

    -- Migration 340: reject a stale event_type_id. NULL is fine -- it
    -- means "not event-driven".
    IF @event_type_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM GRAC_New.event_type_master
                        WHERE event_type_id = @event_type_id)
        THROW 57213, 'sp_practice_obligation_save: unknown event type.', 1;

    -- 412: the Owner is an EMPLOYEE (a Functional User of this
    -- organization), no longer a role name. @owner_employee_id:
    --   NULL = leave the stored owner as it is (older callers),
    --   0    = clear the owner,
    --   > 0  = set it; responsibility (the display name every reader
    --          already shows) is written from the employee record.
    IF @owner_employee_id > 0
    BEGIN
        DECLARE @owner_name NVARCHAR(300) = (
            SELECT e.employee_name
            FROM   grac_practice.organization_employee e
            WHERE  e.employee_id        = @owner_employee_id
              AND  e.organization_id    = @organization_id
              AND  e.status             = N'Active'
              AND  e.is_functional_user = 1);
        IF @owner_name IS NULL
            THROW 57214, 'The obligation owner must be an active Functional User of this organization.', 1;
        SET @responsibility = @owner_name;
    END
    ELSE IF @owner_employee_id = 0
        SET @responsibility = NULL;

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
             responsibility, owner_employee_id, approval_authority, assurance_type, remarks,
             event_type_id,
             evidence_json, status, record_status_id, entered_by)
        VALUES
            (@organization_id, @practice_id,
             @obligation_name, @obligation_description, @obligation_type_code,
             ISNULL(@typed_detail_json, N'[]'),
             @execution_frequency_id, @execution_frequency,
             @responsibility, NULLIF(@owner_employee_id, 0), @approval_authority, @assurance_type, @remarks,
             @event_type_id,
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
           owner_employee_id      = CASE WHEN @owner_employee_id IS NULL THEN owner_employee_id
                                         ELSE NULLIF(@owner_employee_id, 0) END,   -- 412
           approval_authority     = @approval_authority,
           assurance_type         = @assurance_type,
           remarks                = @remarks,
           -- Migration 340: direct write, same contract as assurance_type
           -- above -- the definition's edit form resends the whole
           -- payload, so absent really does mean "not event-driven".
           event_type_id          = @event_type_id,
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

-- =====================================================================
-- 6. sp_practice_obligation_list (340 body + OwnerEmployeeId)
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
           po.owner_employee_id      AS OwnerEmployeeId,   -- 412
           po.approval_authority     AS ApprovalAuthority,
           po.assurance_type         AS AssuranceType,
           po.event_type_id          AS EventTypeId,
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

-- =====================================================================
-- Verification
-- =====================================================================
SELECT '412-a owner_employee_id columns' AS Check_,
       CASE WHEN COL_LENGTH('grac_practice.practice_instance_obligation','owner_employee_id') IS NOT NULL
             AND COL_LENGTH('grac_practice.practice_obligation','owner_employee_id') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL SELECT '412-b adopt reads ownerEmployeeId',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_resolve_obligation_adopt')) LIKE '%ownerEmployeeId%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT '412-c obligation list returns OwnerEmployeeId',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_resolve_obligation_list')) LIKE '%AS OwnerEmployeeId%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT '412-d local save takes @owner_employee_id',
       CASE WHEN EXISTS (SELECT 1 FROM sys.parameters WHERE object_id = OBJECT_ID('grac_practice.sp_resolve_local_obligation_save') AND name = '@owner_employee_id')
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT '412-e practice save takes @owner_employee_id',
       CASE WHEN EXISTS (SELECT 1 FROM sys.parameters WHERE object_id = OBJECT_ID('grac_practice.sp_practice_obligation_save') AND name = '@owner_employee_id')
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT '412-f practice list returns OwnerEmployeeId',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_practice_obligation_list')) LIKE '%AS OwnerEmployeeId%'
            THEN 'PASS' ELSE 'FAIL' END;

-- Information: obligations still carrying a legacy role name as Owner
-- (owner_employee_id NULL). They show the old text until an employee is
-- picked on Operationalize.
SELECT pio.organization_id AS OrganizationId,
       COUNT(1)            AS LegacyRoleOwners
FROM   grac_practice.practice_instance_obligation pio
WHERE  pio.status = N'Active'
  AND  pio.owner_employee_id IS NULL
  AND  NULLIF(LTRIM(RTRIM(pio.responsibility)), N'') IS NOT NULL
GROUP BY pio.organization_id;
GO

SET NOEXEC OFF;
GO
PRINT 'Migration 412_obligation_owner_employee applied. Restart the API.';
GO
