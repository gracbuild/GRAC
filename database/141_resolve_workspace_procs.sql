-- =====================================================================
-- 141 Resolve workspace -- procedures
--
--   grac_practice.sp_resolve_instance_list      the owner-scoped list
--   grac_practice.sp_resolve_instance_detail    workspace header
--   grac_practice.sp_resolve_obligation_list    subscribed obligations
--   grac_practice.sp_resolve_obligation_adopt   adopt / edit / un-adopt
--   grac_practice.sp_resolve_dependency_list    dependency cards
--   grac_practice.sp_resolve_dependency_save    resolve one dependency
--
-- SCOPING
-- -------
-- sp_resolve_instance_list takes @caller_employee_id and @is_admin and
-- filters on practice_instance.primary_owner_id. The caller identity is
-- read from the session in the Web tier, never from the browser, so a
-- user cannot widen their own view by editing a request.
--
-- EVIDENCE TYPE IDS ARE MAPPED BY NAME
-- ------------------------------------
-- GRAC_New.evidence_type_master and grac_practice.evidence_type_master
-- are separate catalogs with separate IDENTITY sequences. Copying an id
-- across would attach evidence of whatever type happens to share that
-- number. The join is on evidence_type_name, and an obligation evidence
-- whose type has no practice-side equivalent is skipped rather than
-- guessed at -- sp_resolve_obligation_adopt reports how many were.
--
-- Error codes 52600-52620 (52500s belong to 139).
-- Depends on 140. Rollback: 141_resolve_workspace_procs_rollback.sql.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.practice_instance_obligation','U') IS NULL
BEGIN
    RAISERROR('141: practice_instance_obligation is missing. Run 140 first.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. sp_resolve_instance_list
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_resolve_instance_list
    @organization_id     BIGINT,
    @caller_employee_id  BIGINT       = NULL,
    @is_admin            BIT          = 0,
    @search              NVARCHAR(200) = N'',
    @page_number         INT          = 1,
    @page_size           INT          = 25
AS
BEGIN
    SET NOCOUNT ON;

    IF @organization_id IS NULL
        THROW 52600, 'sp_resolve_instance_list: organization_id is required.', 1;

    -- A non-admin with no employee id would otherwise see everything.
    IF @is_admin = 0 AND @caller_employee_id IS NULL
        THROW 52601, 'sp_resolve_instance_list: caller_employee_id is required for a non-admin caller.', 1;

    IF @page_size IS NULL OR @page_size <= 0 SET @page_size = 25;
    IF @page_size > 200 SET @page_size = 200;
    IF @page_number IS NULL OR @page_number < 1 SET @page_number = 1;
    IF @search IS NULL SET @search = N'';

    DECLARE @offset INT = (@page_number - 1) * @page_size;

    SELECT
        pi.practice_instance_id      AS PracticeInstanceId,
        pi.instance_code             AS InstanceCode,
        pi.instance_name             AS InstanceName,
        p.practice_id                AS PracticeId,
        p.practice_code              AS PracticeCode,
        p.practice_name              AS PracticeName,
        pi.primary_owner_id          AS OwnerEmployeeId,
        COALESCE(owner_emp.employee_name, pi.primary_owner) AS OwnerName,
        COALESCE(dept.department_name, pi.department)       AS Department,
        pi.criticality               AS Criticality,
        COALESCE(ims.status_name, pi.implementation_status) AS ImplementationStatus,
        pi.status                    AS Status,

        -- Progress, so the list says what still needs doing without the
        -- user opening every row.
        ob.TotalObligations          AS TotalObligations,
        ob.AdoptedObligations        AS AdoptedObligations,
        dep.TotalDependencies        AS TotalDependencies,
        dep.ResolvedDependencies     AS ResolvedDependencies
    FROM   grac_practice.practice_instance pi
    JOIN   grac_practice.practice p
           ON p.practice_id = pi.practice_id
    LEFT   JOIN grac_practice.organization_employee owner_emp
           ON owner_emp.employee_id = pi.primary_owner_id
    LEFT   JOIN grac_practice.organization_department dept
           ON dept.department_id = pi.department_id
    LEFT   JOIN grac_practice.implementation_status_master ims
           ON ims.implementation_status_id = pi.implementation_status_id
    OUTER  APPLY (
        SELECT COUNT(*) AS TotalObligations,
               SUM(CASE WHEN a.practice_instance_obligation_id IS NOT NULL THEN 1 ELSE 0 END) AS AdoptedObligations
        FROM (
            SELECT DISTINCT orm.obligation_id
            FROM   grac_practice.practice pp
            JOIN   grac_practice.organization_requirement req
                   ON req.organization_requirement_id = pp.organization_requirement_id
            LEFT   JOIN GRAC_New.requirement repo_req
                   ON repo_req.requirement_code = req.requirement_code AND repo_req.status = N'Active'
            JOIN   GRAC_New.obligation_requirement_release_map orm
                   ON orm.requirement_id = COALESCE(req.repository_requirement_id, repo_req.requirement_id)
                  AND orm.status = N'Active'
            JOIN   GRAC_New.requirement_obligation ro
                   ON ro.obligation_id = orm.obligation_id AND ro.status = N'Active'
            WHERE  pp.practice_id = pi.practice_id
              AND  EXISTS (SELECT 1 FROM grac_practice.repository_subscription s
                            WHERE s.organization_id = pi.organization_id
                              AND s.release_id = orm.release_id
                              AND s.status = N'Active')
        ) o
        LEFT JOIN grac_practice.practice_instance_obligation a
               ON a.practice_instance_id = pi.practice_instance_id
              AND a.obligation_id        = o.obligation_id
              AND a.status               = N'Active'
    ) ob
    OUTER  APPLY (
        SELECT COUNT(DISTINCT d.dependency_type_id) AS TotalDependencies,
               COUNT(DISTINCT r.dependency_type_id) AS ResolvedDependencies
        FROM   grac_practice.practice_instance_dependency d
        LEFT   JOIN grac_practice.practice_dependency_resolution r
               ON r.practice_instance_id = d.practice_instance_id
              AND r.dependency_type_id   = d.dependency_type_id
              AND r.is_active            = 1
        WHERE  d.practice_instance_id = pi.practice_instance_id
          AND  d.status = N'Active'
    ) dep
    WHERE  pi.organization_id = @organization_id
      AND  pi.status = N'Active'
      AND (@is_admin = 1 OR pi.primary_owner_id = @caller_employee_id)
      AND (@search = N''
           OR pi.instance_code LIKE N'%' + @search + N'%'
           OR pi.instance_name LIKE N'%' + @search + N'%'
           OR p.practice_code  LIKE N'%' + @search + N'%'
           OR p.practice_name  LIKE N'%' + @search + N'%')
    ORDER  BY pi.instance_code
    OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
END
GO

-- =====================================================================
-- 2. sp_resolve_instance_detail
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_resolve_instance_detail
    @practice_instance_id BIGINT,
    @organization_id      BIGINT = NULL,
    @caller_employee_id   BIGINT = NULL,
    @is_admin             BIT    = 0
AS
BEGIN
    SET NOCOUNT ON;

    IF @practice_instance_id IS NULL
        THROW 52602, 'sp_resolve_instance_detail: practice_instance_id is required.', 1;

    IF NOT EXISTS (SELECT 1 FROM grac_practice.practice_instance
                    WHERE practice_instance_id = @practice_instance_id
                      AND (@organization_id IS NULL OR organization_id = @organization_id))
        THROW 52603, 'sp_resolve_instance_detail: instance not found for this organization.', 1;

    -- The list already hides instances the caller does not own, but the
    -- workspace is reachable by URL. Without this check, changing one
    -- number in the address bar opens a colleague's instance -- and the
    -- obligation and dependency endpoints hang off whatever opens here.
    IF @is_admin = 0
       AND NOT EXISTS (SELECT 1 FROM grac_practice.practice_instance
                        WHERE practice_instance_id = @practice_instance_id
                          AND primary_owner_id = @caller_employee_id)
        THROW 52619, 'sp_resolve_instance_detail: this practice instance belongs to another owner.', 1;

    SELECT
        pi.practice_instance_id  AS PracticeInstanceId,
        pi.organization_id       AS OrganizationId,
        o.organization_name      AS OrganizationName,
        pi.instance_code         AS InstanceCode,
        pi.instance_name         AS InstanceName,
        p.practice_id            AS PracticeId,
        p.practice_code          AS PracticeCode,
        p.practice_name          AS PracticeName,
        pi.primary_owner_id      AS OwnerEmployeeId,
        COALESCE(owner_emp.employee_name, pi.primary_owner) AS OwnerName,
        COALESCE(dept.department_name, pi.department)       AS Department,
        ef.frequency_name        AS ExecutionFrequency,
        af.frequency_name        AS AssuranceFrequency,
        pi.assurance_mode        AS AssuranceMode,
        pi.criticality           AS Criticality,
        COALESCE(ims.status_name, pi.implementation_status) AS ImplementationStatus,
        pi.status                AS Status
    FROM   grac_practice.practice_instance pi
    JOIN   grac_practice.practice p ON p.practice_id = pi.practice_id
    JOIN   grac_practice.organization o ON o.organization_id = pi.organization_id
    LEFT   JOIN grac_practice.organization_employee owner_emp
           ON owner_emp.employee_id = pi.primary_owner_id
    LEFT   JOIN grac_practice.organization_department dept
           ON dept.department_id = pi.department_id
    LEFT   JOIN grac_practice.frequency_master ef ON ef.frequency_id = pi.execution_frequency_id
    LEFT   JOIN grac_practice.frequency_master af ON af.frequency_id = pi.assurance_frequency_id
    LEFT   JOIN grac_practice.implementation_status_master ims
           ON ims.implementation_status_id = pi.implementation_status_id
    WHERE  pi.practice_instance_id = @practice_instance_id;
END
GO

-- =====================================================================
-- 3. sp_resolve_obligation_list
--
--    One row per obligation reachable from the instance's practice, via
--    a release the organization actually subscribes to, de-duplicated --
--    the same obligation can be mapped to a requirement more than once
--    and can ride several releases.
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
    -- One row per obligation. Where the same obligation rides several
    -- subscribed releases, the lowest release_id is the representative --
    -- an arbitrary but stable choice, so the card does not reshuffle
    -- between loads.
    picked AS (
        SELECT obligation_id,
               MIN(release_id)      AS release_id,
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

        -- As published.
        COALESCE(exec_freq.option_label, o.frequency_type) AS PublishedExecutionFrequency,
        o.responsibility                AS PublishedResponsibility,
        o.approval_authority            AS PublishedApprovalAuthority,
        o.retention_requirement         AS PublishedRetention,

        -- As adopted here. NULL until the organization adopts it.
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

        -- What adopting will create, and what already exists.
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
        SELECT COUNT(DISTINCT roe.evidence_type_id) AS PublishedEvidenceCount,
               (SELECT COUNT(*) FROM grac_practice.practice_instance_evidence pie
                 WHERE pie.practice_instance_id = @practice_instance_id
                   AND pie.source_obligation_id = pk.obligation_id
                   AND pie.status = N'Active') AS ResolvedEvidenceCount
        FROM   GRAC_New.requirement_obligation_evidence roe
        WHERE  roe.obligation_id = pk.obligation_id
    ) ev
    ORDER  BY ISNULL(t.display_order, 999),
              COALESCE(o.obligation_name, o.obligation_text);
END
GO

-- =====================================================================
-- 4. sp_resolve_obligation_adopt
--
--    @payload_json is an array:
--      [{ "obligationId": 12, "isAdopted": true,
--         "executionFrequencyId": 3, "executionFrequency": "Monthly",
--         "assuranceFrequencyId": null, "assuranceFrequency": null,
--         "responsibility": "...", "approvalAuthority": "...",
--         "retentionPeriod": "...", "remarks": "..." }]
--
--    organization_modified is DERIVED, never taken from the caller: a
--    row counts as modified when a supplied parameter differs from what
--    the authority published. Trusting a client-sent flag would let a
--    screen mislabel an edit as an as-published adoption, which is the
--    one thing this table exists to record accurately.
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

    -- practice_instance_evidence.collection_method_id and
    -- alignment_status_id are NOT NULL, so both have to be resolved
    -- before any evidence row can be written.
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

    -- ---------------------------------------------------------------
    -- Read the request, and pull the published values alongside so the
    -- modified flag can be derived rather than believed.
    -- ---------------------------------------------------------------
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

    -- Representative subscribed release, matching sp_resolve_obligation_list.
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

    -- Derived, not supplied. NULL means "left as published", so only a
    -- value that is present AND different counts as a change.
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

    -- ---------------- adopt / update ----------------
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

    -- ---------------- un-adopt ----------------
    -- Retired, not deleted: the fact that this instance once took the
    -- obligation on is itself an audit answer.
    UPDATE pio
       SET status     = N'Retired',
           updated_by = @actor,
           updated_dt = SYSUTCDATETIME()
    FROM  grac_practice.practice_instance_obligation pio
    JOIN  @req r ON r.ObligationId = pio.obligation_id
    WHERE pio.practice_instance_id = @practice_instance_id
      AND r.IsAdopted = 0
      AND pio.status = N'Active';

    -- Evidence that came from an un-adopted obligation and that nobody
    -- has filled in goes with it. A row somebody has already resolved --
    -- given a location, a locator or an owner -- stays: their work is
    -- not this procedure's to throw away.
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

    -- ---------------- evidence auto-create ----------------
    -- Types are matched by NAME across the two catalogs; see the header.
    INSERT grac_practice.practice_instance_evidence
        (organization_id, practice_instance_id, evidence_type_id,
         inherited_from_repository, organization_modified, is_mandatory,
         collection_method_id, collection_frequency_id, retention_period,
         alignment_status_id, source_obligation_id, source_obligation_evidence_id,
         status, record_status_id, entered_by)
    SELECT DISTINCT
           @organization_id, @practice_instance_id, pet.evidence_type_id,
           1, 0, 1,
           @collection_method_id, NULL, roe.retention_requirement,
           @inherited_alignment_id, r.ObligationId, roe.obligation_evidence_id,
           N'Active', @active_record_status_id, @actor
    FROM   @req r
    JOIN   GRAC_New.requirement_obligation_evidence roe
           ON roe.obligation_id = r.ObligationId
    JOIN   GRAC_New.evidence_type_master get
           ON get.evidence_type_id = roe.evidence_type_id
    JOIN   grac_practice.evidence_type_master pet
           ON pet.evidence_type_name = get.evidence_type_name
          AND pet.is_active = 1
    WHERE  r.IsAdopted = 1
      AND  NOT EXISTS (SELECT 1 FROM grac_practice.practice_instance_evidence x
                        WHERE x.practice_instance_id = @practice_instance_id
                          AND x.evidence_type_id     = pet.evidence_type_id
                          AND x.status = N'Active');

    COMMIT TRAN;

    -- ---------------- result ----------------
    -- Per obligation, so the screen can report what actually happened
    -- instead of a blanket success. UnmappedEvidenceTypes is the count of
    -- published evidence types with no practice-side equivalent -- those
    -- were skipped, and saying so is the point.
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
           (SELECT COUNT(DISTINCT roe.evidence_type_id)
              FROM GRAC_New.requirement_obligation_evidence roe
              JOIN GRAC_New.evidence_type_master get ON get.evidence_type_id = roe.evidence_type_id
             WHERE roe.obligation_id = r.ObligationId
               AND NOT EXISTS (SELECT 1 FROM grac_practice.evidence_type_master pet
                                WHERE pet.evidence_type_name = get.evidence_type_name
                                  AND pet.is_active = 1)) AS UnmappedEvidenceTypes
    FROM   @req r
    ORDER  BY r.ObligationName;
END
GO

-- =====================================================================
-- 5. sp_resolve_dependency_list
--
--    One row per dependency category the instance declares, with its
--    current resolution. The picker's options are loaded separately by
--    the existing dependency-options endpoint.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_resolve_dependency_list
    @practice_instance_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    IF @practice_instance_id IS NULL
        THROW 52613, 'sp_resolve_dependency_list: practice_instance_id is required.', 1;

    SELECT
        d.dependency_type_id                          AS DependencyTypeId,
        COALESCE(dt.dependency_type_name, d.dependency_type) AS DependencyCategory,
        MIN(d.dependency_id)                          AS DependencyId,
        COUNT(DISTINCT r.resolution_id)               AS ResolvedCount,
        STUFF((SELECT N', ' + r2.resolved_dependency_name
               FROM   grac_practice.practice_dependency_resolution r2
               WHERE  r2.practice_instance_id = @practice_instance_id
                 AND  r2.dependency_type_id   = d.dependency_type_id
                 AND  r2.is_active = 1
               ORDER  BY r2.resolved_dependency_name
               FOR XML PATH(''), TYPE).value('.','NVARCHAR(MAX)'), 1, 2, N'') AS ResolvedNames,
        CAST(CASE WHEN COUNT(DISTINCT r.resolution_id) > 0 THEN 1 ELSE 0 END AS BIT) AS IsResolved
    FROM   grac_practice.practice_instance_dependency d
    LEFT   JOIN grac_practice.dependency_type_master dt
           ON dt.dependency_type_id = d.dependency_type_id
    LEFT   JOIN grac_practice.practice_dependency_resolution r
           ON r.practice_instance_id = d.practice_instance_id
          AND r.dependency_type_id   = d.dependency_type_id
          AND r.is_active            = 1
    WHERE  d.practice_instance_id = @practice_instance_id
      AND  d.status = N'Active'
      AND  d.dependency_type_id IS NOT NULL
    GROUP  BY d.dependency_type_id, COALESCE(dt.dependency_type_name, d.dependency_type)
    ORDER  BY DependencyCategory;

    -- Second result set: the individual resolutions, so a card can list
    -- and remove them without a second round trip.
    SELECT r.resolution_id            AS ResolutionId,
           r.dependency_type_id       AS DependencyTypeId,
           r.resolved_dependency_id   AS ResolvedDependencyId,
           r.resolved_dependency_name AS ResolvedDependencyName,
           r.resolution_owner_id      AS ResolutionOwnerId,
           e.employee_name            AS ResolutionOwnerName,
           r.remarks                  AS Remarks,
           r.resolution_status        AS ResolutionStatus
    FROM   grac_practice.practice_dependency_resolution r
    LEFT   JOIN grac_practice.organization_employee e
           ON e.employee_id = r.resolution_owner_id
    WHERE  r.practice_instance_id = @practice_instance_id
      AND  r.is_active = 1
    ORDER  BY r.dependency_type_id, r.resolved_dependency_name;
END
GO

-- =====================================================================
-- 6. sp_resolve_dependency_save
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_resolve_dependency_save
    @practice_instance_id   BIGINT,
    @dependency_type_id     INT,
    @resolved_dependency_id BIGINT,
    @resolved_name          NVARCHAR(300),
    @resolution_owner_id    BIGINT       = NULL,
    @remarks                NVARCHAR(MAX) = NULL,
    @actor                  NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @practice_instance_id IS NULL OR @dependency_type_id IS NULL OR @resolved_dependency_id IS NULL
        THROW 52614, 'sp_resolve_dependency_save: instance, dependency type and resolved object are all required.', 1;
    IF NULLIF(LTRIM(RTRIM(ISNULL(@resolved_name, N''))), N'') IS NULL
        THROW 52615, 'sp_resolve_dependency_save: the resolved object name is required.', 1;

    DECLARE @organization_id BIGINT;
    SELECT @organization_id = organization_id
    FROM   grac_practice.practice_instance
    WHERE  practice_instance_id = @practice_instance_id;
    IF @organization_id IS NULL
        THROW 52616, 'sp_resolve_dependency_save: instance not found.', 1;

    -- Only a category the instance actually declares can be resolved --
    -- otherwise the workspace could invent dependencies the practice
    -- never asked for.
    IF NOT EXISTS (SELECT 1 FROM grac_practice.practice_instance_dependency d
                    WHERE d.practice_instance_id = @practice_instance_id
                      AND d.dependency_type_id   = @dependency_type_id
                      AND d.status = N'Active')
        THROW 52617, 'sp_resolve_dependency_save: this instance does not declare that dependency category.', 1;

    DECLARE @active_record_status_id INT = (
        SELECT TOP 1 record_status_id FROM grac_practice.record_status_master
        WHERE status_code = 'ACTIVE' OR status_name = 'Active' ORDER BY record_status_id);
    DECLARE @resolved_status_id INT = (
        SELECT TOP 1 resolution_status_id FROM grac_practice.dependency_resolution_status_master
        WHERE status_code = N'Resolved' ORDER BY resolution_status_id);
    IF @resolved_status_id IS NULL
        THROW 52618, 'sp_resolve_dependency_save: Resolved dependency status is missing.', 1;

    DECLARE @category NVARCHAR(120) = (
        SELECT TOP 1 COALESCE(dt.dependency_type_name, d.dependency_type)
        FROM   grac_practice.practice_instance_dependency d
        LEFT   JOIN grac_practice.dependency_type_master dt
               ON dt.dependency_type_id = d.dependency_type_id
        WHERE  d.practice_instance_id = @practice_instance_id
          AND  d.dependency_type_id   = @dependency_type_id);

    BEGIN TRAN;

    -- uq_pm_practice_dependency_resolution is on
    -- (organization_id, practice_instance_id, dependency_type_id,
    --  resolved_dependency_id), so MERGE on exactly that key.
    MERGE grac_practice.practice_dependency_resolution AS target
    USING (SELECT @organization_id AS organization_id,
                  @practice_instance_id AS practice_instance_id,
                  @dependency_type_id AS dependency_type_id,
                  @resolved_dependency_id AS resolved_dependency_id) AS src
       ON target.organization_id        = src.organization_id
      AND target.practice_instance_id   = src.practice_instance_id
      AND target.dependency_type_id     = src.dependency_type_id
      AND target.resolved_dependency_id = src.resolved_dependency_id
    WHEN MATCHED THEN UPDATE SET
        resolved_dependency_name = @resolved_name,
        resolution_status_id     = @resolved_status_id,
        resolution_status        = N'Resolved',
        resolution_owner_id      = @resolution_owner_id,
        resolution_dt            = SYSUTCDATETIME(),
        remarks                  = @remarks,
        is_active                = 1,
        record_status_id         = @active_record_status_id,
        updated_by               = @actor,
        updated_dt               = SYSUTCDATETIME()
    WHEN NOT MATCHED THEN INSERT
        (organization_id, practice_instance_id, dependency_type_id, dependency_category,
         resolved_dependency_id, resolved_dependency_name, resolution_status_id,
         resolution_status, resolution_owner_id, resolution_dt, remarks,
         is_active, record_status_id, entered_by)
    VALUES
        (@organization_id, @practice_instance_id, @dependency_type_id, ISNULL(@category, N'Dependency'),
         @resolved_dependency_id, @resolved_name, @resolved_status_id,
         N'Resolved', @resolution_owner_id, SYSUTCDATETIME(), @remarks,
         1, @active_record_status_id, @actor);

    COMMIT TRAN;

    SELECT CAST(1 AS BIT) AS Success,
           N'Dependency resolved.' AS Message,
           (SELECT COUNT(*) FROM grac_practice.practice_dependency_resolution
             WHERE practice_instance_id = @practice_instance_id AND is_active = 1) AS ResolvedCount;
END
GO

-- =====================================================================
-- Sanity report
-- =====================================================================
SELECT o.name AS Procedure_, 'PASS' AS Result
FROM   sys.objects o
WHERE  o.type = 'P'
  AND  o.name IN ('sp_resolve_instance_list','sp_resolve_instance_detail',
                  'sp_resolve_obligation_list','sp_resolve_obligation_adopt',
                  'sp_resolve_dependency_list','sp_resolve_dependency_save')
  AND  SCHEMA_NAME(o.schema_id) = 'grac_practice'
ORDER  BY o.name;

-- Evidence types published by obligations that have no practice-side
-- equivalent. Adoption skips these; add them to
-- grac_practice.evidence_type_master to have them created.
SELECT DISTINCT get.evidence_type_name AS UnmappedEvidenceType
FROM   GRAC_New.requirement_obligation_evidence roe
JOIN   GRAC_New.evidence_type_master get ON get.evidence_type_id = roe.evidence_type_id
WHERE  NOT EXISTS (SELECT 1 FROM grac_practice.evidence_type_master pet
                    WHERE pet.evidence_type_name = get.evidence_type_name
                      AND pet.is_active = 1)
ORDER  BY UnmappedEvidenceType;

PRINT '141 Resolve workspace procedures installed.';
PRINT 'Any evidence type listed above is published but has no practice-side match,';
PRINT 'so adopting an obligation will not create a row for it.';
GO
