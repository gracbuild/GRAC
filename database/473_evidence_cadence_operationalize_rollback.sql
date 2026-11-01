-- =====================================================================
-- 473_evidence_cadence_operationalize_rollback.sql
--
-- Reverses 473:
--   1. Re-issues, verbatim, the bodies 473 replaced:
--        sp_resolve_obligation_list      (457)
--        sp_resolve_evidence_list        (394)
--        sp_resolve_evidence_save        (254)  -- drops @clear_evidence_description
--        sp_task_completion_eligibility  (194)  -- drops the evidence gate
--                                               ('-' for the em dash, ASCII-only)
--   2. Drops the procedures and the view 473 added.
--   3. practice_instance_evidence_attachment is dropped ONLY when it holds
--      no rows. Files someone attached are not deleted by a rollback; the
--      table is left in place and the script says so.
--   4. @clear_description_overrides = 1 (default) sets
--      practice_instance_obligation.obligation_description back to NULL on
--      ADOPTED (published) rows -- 473 is the only writer of that column
--      for those rows, and without 473's screen the edits could not be
--      seen or undone, while 459 would keep putting them on scheduled
--      tasks. Organisation-defined rows (obligation_id IS NULL) are never
--      touched. Set it to 0 to keep the edits.
--   NOT reversed: organization_obligation_evidence.evidence_cadence and
--   the rebuilt vw_repo_src_obligation_evidence. They mirror Control
--   Management 077 and are what re-running 391 would produce anyway.
--
-- Turn the API / Web change off first (or deploy the previous build): the
-- screens call the procedures this drops.
-- SAFE TO RE-RUN. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

-- ---------------------------------------------------------------------
-- 1a. sp_resolve_obligation_list (457 body)
-- ---------------------------------------------------------------------
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
        -- 457: the first-occurrence anchor (338), read back so the
        -- Operationalize date input shows what was saved.
        adopt.first_occurrence_date     AS FirstOccurrenceDate,
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
        pio.first_occurrence_date       AS FirstOccurrenceDate,
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

-- ---------------------------------------------------------------------
-- 1b. sp_resolve_evidence_list (394 body)
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE grac_practice.sp_resolve_evidence_list
    @practice_instance_id BIGINT,
    @obligation_id        BIGINT = NULL,
    -- 232. Filters to one organisation-defined obligation. Separate from
    -- @obligation_id rather than overloading it: they index different
    -- tables, and a NULL @obligation_id already means "every row".
    @practice_instance_obligation_id BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @practice_instance_id IS NULL
        THROW 52640, 'sp_resolve_evidence_list: practice_instance_id is required.', 1;

    -- 394: repository evidence text comes from the organization's copy.
    DECLARE @copy_organization_id BIGINT = (
        SELECT organization_id FROM grac_practice.practice_instance
        WHERE practice_instance_id = @practice_instance_id);

    SELECT
        e.evidence_id             AS EvidenceId,
        e.source_obligation_id    AS SourceObligationId,
        -- 231/232. A locally added obligation has no GRAC_New id, so this
        -- is what says which one an evidence row belongs to.
        e.source_practice_instance_obligation_id AS SourcePracticeInstanceObligationId,
        -- Migration 254: the organisation's own label for this row.
        e.evidence_name           AS EvidenceName,
        e.evidence_type_id        AS EvidenceTypeId,
        et.evidence_type_name     AS EvidenceType,

        -- Migration 306: what the authority published as the instruction
        -- for this evidence. Exact source row first, then the
        -- obligation + type fallback for a row that has no
        -- source_obligation_evidence_id.
        -- CAST before LTRIM/RTRIM: the column is repository-owned, and
        -- LTRIM on an ntext argument is Msg 8116, not a NULL. Casting
        -- costs nothing when it is already NVARCHAR(MAX) and removes the
        -- guess about which it is.
        COALESCE(
            (SELECT TOP 1 NULLIF(LTRIM(RTRIM(CAST(roe.remarks AS NVARCHAR(MAX)))), N'')
             FROM   grac_practice.fn_org_requirement_obligation_evidence(@copy_organization_id) roe
             WHERE  roe.obligation_evidence_id = e.source_obligation_evidence_id
               AND  roe.status = N'Active'),
            (SELECT TOP 1 NULLIF(LTRIM(RTRIM(CAST(roe2.remarks AS NVARCHAR(MAX)))), N'')
             FROM   grac_practice.vw_pm_obligation_evidence oe
             JOIN   grac_practice.fn_org_requirement_obligation_evidence(@copy_organization_id) roe2
                    ON roe2.obligation_evidence_id = oe.obligation_evidence_id
             JOIN   GRAC_New.evidence_type_master get
                    ON get.evidence_type_id = oe.evidence_type_id
             JOIN   grac_practice.evidence_type_master pet
                    ON pet.evidence_type_name = get.evidence_type_name
                   AND pet.is_active = 1
             WHERE  oe.organization_id    = @copy_organization_id
               AND  oe.obligation_id      = e.source_obligation_id
               AND  pet.evidence_type_id  = e.evidence_type_id
               AND  roe2.status = N'Active'
               AND  NULLIF(LTRIM(RTRIM(CAST(roe2.remarks AS NVARCHAR(MAX)))), N'') IS NOT NULL
             ORDER  BY oe.obligation_evidence_id)
        )                         AS EvidenceRemarks,

        e.is_mandatory            AS IsMandatory,
        e.collection_method_id    AS CollectionMethodId,
        cm.collection_method_name AS CollectionMethod,
        e.collection_frequency_id AS CollectionFrequencyId,
        f.frequency_name          AS CollectionFrequency,
        e.assurance_type_id       AS AssuranceTypeId,
        at2.assurance_type_name   AS AssuranceType,
        e.retention_period        AS RetentionPeriod,
        e.evidence_owner          AS EvidenceOwner,
        e.evidence_description    AS EvidenceDescription,
        e.evidence_location       AS EvidenceLocation,
        e.evidence_locator        AS EvidenceLocator,
        e.alignment_status_id     AS AlignmentStatusId,
        al.alignment_status_name  AS AlignmentStatus,
        e.inherited_from_repository AS InheritedFromRepository,
        e.organization_modified     AS OrganizationModified,

        -- The same two-field test assurance eligibility applies, so the
        -- workspace cannot report ready on a row assurance would reject.
        -- Migration 254 deliberately does NOT add the name here, and 306
        -- does not add the remark: a published instruction is not an
        -- organisation answer, so it cannot move a row towards resolved.
        CAST(CASE WHEN NULLIF(LTRIM(RTRIM(ISNULL(e.evidence_location, N''))), N'') IS NOT NULL
                   AND NULLIF(LTRIM(RTRIM(ISNULL(e.evidence_locator,  N''))), N'') IS NOT NULL
                  THEN 1 ELSE 0 END AS BIT) AS IsResolved
    FROM   grac_practice.practice_instance_evidence e
    LEFT   JOIN grac_practice.evidence_type_master et
           ON et.evidence_type_id = e.evidence_type_id
    LEFT   JOIN grac_practice.collection_method_master cm
           ON cm.collection_method_id = e.collection_method_id
    LEFT   JOIN grac_practice.frequency_master f
           ON f.frequency_id = e.collection_frequency_id
    LEFT   JOIN grac_practice.assurance_type_master at2
           ON at2.assurance_type_id = e.assurance_type_id
    LEFT   JOIN grac_practice.evidence_alignment_status_master al
           ON al.alignment_status_id = e.alignment_status_id
    WHERE  e.practice_instance_id = @practice_instance_id
      AND  e.status = N'Active'
      AND (@obligation_id IS NULL OR e.source_obligation_id = @obligation_id)
      AND (@practice_instance_obligation_id IS NULL
           OR e.source_practice_instance_obligation_id = @practice_instance_obligation_id)
    ORDER  BY CASE WHEN e.source_obligation_id IS NULL THEN 1 ELSE 0 END,
              e.source_obligation_id,
              -- Migration 254: a named row sorts by its name, an unnamed
              -- one keeps sorting by type, so adding a name never scatters
              -- the list into a new order the operator did not ask for.
              COALESCE(NULLIF(LTRIM(RTRIM(e.evidence_name)), N''), et.evidence_type_name);
END
GO

-- ---------------------------------------------------------------------
-- 1c. sp_resolve_evidence_save (254 body)
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE grac_practice.sp_resolve_evidence_save
    @practice_instance_id   BIGINT,
    @evidence_id            BIGINT,
    @is_mandatory           BIT           = NULL,
    @collection_method_id   INT           = NULL,
    @collection_frequency_id INT          = NULL,
    @assurance_type_id      INT           = NULL,
    @retention_period       NVARCHAR(120) = NULL,
    @owner_employee_id      BIGINT        = NULL,
    @clear_owner            BIT           = 0,
    @evidence_description   NVARCHAR(MAX) = NULL,
    @evidence_location      NVARCHAR(500) = NULL,
    @evidence_locator       NVARCHAR(500) = NULL,
    -- Migration 254. NULL means "unchanged", same contract as every other
    -- optional field here.
    @evidence_name          NVARCHAR(300) = NULL,
    @actor                  NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @practice_instance_id IS NULL OR @evidence_id IS NULL
        THROW 52641, 'sp_resolve_evidence_save: practice instance and evidence row are both required.', 1;

    DECLARE @organization_id BIGINT;
    SELECT @organization_id = e.organization_id
    FROM   grac_practice.practice_instance_evidence e
    WHERE  e.evidence_id          = @evidence_id
      AND  e.practice_instance_id = @practice_instance_id
      AND  e.status = N'Active';

    -- Scoped to the instance the caller already opened, so an evidence id
    -- from somewhere else matches nothing rather than being editable by
    -- guessing the number.
    IF @organization_id IS NULL
        THROW 52642, 'sp_resolve_evidence_save: that evidence row was not found on this practice instance.', 1;

    -- The owner picker is filled from the shared lookups feed, which is
    -- not scoped to one organization. Verify before writing the name.
    DECLARE @owner_name NVARCHAR(200) = NULL;
    IF @owner_employee_id IS NOT NULL
    BEGIN
        SELECT @owner_name = e.employee_name
        FROM   grac_practice.organization_employee e
        WHERE  e.employee_id     = @owner_employee_id
          AND  e.organization_id = @organization_id
          AND  e.status          = N'Active';

        IF @owner_name IS NULL
            THROW 52643, 'sp_resolve_evidence_save: the evidence owner must be an active employee of this organization.', 1;
    END

    IF @collection_method_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM grac_practice.collection_method_master
                        WHERE collection_method_id = @collection_method_id AND is_active = 1)
        THROW 52644, 'sp_resolve_evidence_save: that collection method does not exist.', 1;

    IF @collection_frequency_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM grac_practice.frequency_master
                        WHERE frequency_id = @collection_frequency_id AND is_active = 1)
        THROW 52645, 'sp_resolve_evidence_save: that collection frequency does not exist.', 1;

    -- Alignment: once the organization sets any of its own parameters the
    -- row is no longer what the repository published. Worked out from the
    -- values after the update rather than taken from the caller.
    DECLARE @org_defined_id INT = (
        SELECT TOP 1 alignment_status_id FROM grac_practice.evidence_alignment_status_master
        WHERE is_active = 1 AND alignment_status_code = N'Organization Defined'
        ORDER BY alignment_status_id);
    DECLARE @inherited_id INT = (
        SELECT TOP 1 alignment_status_id FROM grac_practice.evidence_alignment_status_master
        WHERE is_active = 1 AND alignment_status_code = N'Inherited'
        ORDER BY alignment_status_id);

    UPDATE e
       SET is_mandatory            = COALESCE(@is_mandatory, e.is_mandatory),
           collection_method_id    = COALESCE(@collection_method_id, e.collection_method_id),
           collection_frequency_id = COALESCE(@collection_frequency_id, e.collection_frequency_id),
           assurance_type_id       = COALESCE(@assurance_type_id, e.assurance_type_id),
           retention_period        = COALESCE(@retention_period, e.retention_period),
           evidence_owner          = CASE WHEN @clear_owner = 1 THEN NULL
                                          ELSE COALESCE(@owner_name, e.evidence_owner) END,
           evidence_name           = COALESCE(@evidence_name, e.evidence_name),
           evidence_description    = COALESCE(@evidence_description, e.evidence_description),
           evidence_location       = COALESCE(@evidence_location, e.evidence_location),
           evidence_locator        = COALESCE(@evidence_locator, e.evidence_locator),
           organization_modified   = 1,
           alignment_status_id     = COALESCE(@org_defined_id, e.alignment_status_id),
           updated_by              = @actor,
           updated_dt              = SYSUTCDATETIME()
    FROM   grac_practice.practice_instance_evidence e
    WHERE  e.evidence_id          = @evidence_id
      AND  e.practice_instance_id = @practice_instance_id;

    -- A row that was only ever touched to blank things back out is
    -- inherited again; saying otherwise would overstate what the
    -- organization has decided. Migration 254 adds the name to this test
    -- for the same reason evidence_description is already in it.
    UPDATE e
       SET organization_modified = 0,
           alignment_status_id   = COALESCE(@inherited_id, e.alignment_status_id)
    FROM   grac_practice.practice_instance_evidence e
    WHERE  e.evidence_id          = @evidence_id
      AND  e.practice_instance_id = @practice_instance_id
      AND  e.inherited_from_repository = 1
      AND  NULLIF(LTRIM(RTRIM(ISNULL(e.evidence_location,    N''))), N'') IS NULL
      AND  NULLIF(LTRIM(RTRIM(ISNULL(e.evidence_locator,     N''))), N'') IS NULL
      AND  NULLIF(LTRIM(RTRIM(ISNULL(e.evidence_owner,       N''))), N'') IS NULL
      AND  NULLIF(LTRIM(RTRIM(ISNULL(e.evidence_name,        N''))), N'') IS NULL
      AND  NULLIF(LTRIM(RTRIM(ISNULL(e.evidence_description, N''))), N'') IS NULL;

    SELECT CAST(1 AS BIT) AS Success,
           e.evidence_id  AS EvidenceId,
           CAST(CASE WHEN NULLIF(LTRIM(RTRIM(ISNULL(e.evidence_location, N''))), N'') IS NOT NULL
                      AND NULLIF(LTRIM(RTRIM(ISNULL(e.evidence_locator,  N''))), N'') IS NOT NULL
                     THEN 1 ELSE 0 END AS BIT) AS IsResolved,
           (SELECT COUNT(*) FROM grac_practice.practice_instance_evidence x
             WHERE x.practice_instance_id = @practice_instance_id
               AND x.status = N'Active'
               AND NULLIF(LTRIM(RTRIM(ISNULL(x.evidence_location, N''))), N'') IS NOT NULL
               AND NULLIF(LTRIM(RTRIM(ISNULL(x.evidence_locator,  N''))), N'') IS NOT NULL) AS ResolvedOnInstance,
           N'Evidence saved.' AS Message
    FROM   grac_practice.practice_instance_evidence e
    WHERE  e.evidence_id = @evidence_id;
END
GO

-- ---------------------------------------------------------------------
-- 1d. sp_task_completion_eligibility (194 body)
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE grac_practice.sp_task_completion_eligibility
    @task_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    IF @task_id IS NULL
        THROW 55680, 'sp_task_completion_eligibility: task_id is required.', 1;

    DECLARE @closed_at DATETIME2, @exists BIT = 0;
    SELECT @closed_at = closed_at, @exists = 1
      FROM grac_practice.practice_task WHERE task_id = @task_id;

    IF @exists = 0
        THROW 55681, 'sp_task_completion_eligibility: task not found.', 1;

    DECLARE @child_total     INT = 0,
            @mand_total      INT = 0,
            @mand_completed  INT = 0;

    SELECT @child_total    = COUNT(*),
           @mand_total     = SUM(CASE WHEN ISNULL(c.is_mandatory_child, 1) = 1 THEN 1 ELSE 0 END),
           @mand_completed = SUM(CASE WHEN ISNULL(c.is_mandatory_child, 1) = 1
                                       AND c.closed_at IS NOT NULL THEN 1 ELSE 0 END)
      FROM grac_practice.practice_task c
     WHERE c.parent_task_id = @task_id;

    SET @mand_total     = ISNULL(@mand_total, 0);
    SET @mand_completed = ISNULL(@mand_completed, 0);

    DECLARE @eligible BIT, @reason NVARCHAR(300);

    IF @closed_at IS NOT NULL
    BEGIN
        SET @eligible = 0;
        SET @reason   = N'Task is already completed.';
    END
    ELSE IF @mand_total > @mand_completed
    BEGIN
        SET @eligible = 0;
        SET @reason   = CONCAT(N'Waiting on ', @mand_total - @mand_completed,
                               N' of ', @mand_total, N' mandatory child task(s).');
    END
    ELSE
    BEGIN
        SET @eligible = 1;
        SET @reason   = CASE WHEN @child_total = 0
                             THEN N'No child tasks - ready to complete.'
                             ELSE N'All mandatory child tasks are complete - ready for owner confirmation.'
                        END;
    END

    SELECT @task_id        AS TaskId,
           @eligible       AS IsEligible,
           @reason         AS Reason,
           @child_total    AS ChildCount,
           @mand_total     AS MandatoryChildCount,
           @mand_completed AS MandatoryChildCompletedCount,
           @mand_total - @mand_completed AS MandatoryChildOpenCount;
END;
GO

-- =====================================================================
-- 2. Procedures and view added by 473
-- =====================================================================
DROP PROCEDURE IF EXISTS grac_practice.sp_resolve_obligation_description_save;
DROP PROCEDURE IF EXISTS grac_practice.sp_resolve_evidence_attachment_add;
DROP PROCEDURE IF EXISTS grac_practice.sp_resolve_evidence_attachment_list;
DROP PROCEDURE IF EXISTS grac_practice.sp_resolve_evidence_attachment_get;
DROP PROCEDURE IF EXISTS grac_practice.sp_resolve_evidence_attachment_remove;
GO
-- After the four re-issues above nothing reads the view.
DROP VIEW IF EXISTS grac_practice.vw_pm_instance_evidence_cadence;
GO

-- =====================================================================
-- 3. Attachment table -- only when empty
-- =====================================================================
IF OBJECT_ID('grac_practice.practice_instance_evidence_attachment','U') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM grac_practice.practice_instance_evidence_attachment)
        PRINT '473 rollback: practice_instance_evidence_attachment holds files -- table KEPT. Drop it by hand once they are no longer needed.';
    ELSE
    BEGIN
        DROP TABLE grac_practice.practice_instance_evidence_attachment;
        PRINT '473 rollback: practice_instance_evidence_attachment dropped (it was empty).';
    END
END
GO

-- =====================================================================
-- 4. Description edits on adopted obligations
-- =====================================================================
DECLARE @clear_description_overrides BIT = 1;
IF @clear_description_overrides = 1
BEGIN
    UPDATE grac_practice.practice_instance_obligation
       SET obligation_description = NULL,
           updated_by             = N'rollback-473',
           updated_dt             = SYSUTCDATETIME()
     WHERE obligation_id IS NOT NULL
       AND obligation_description IS NOT NULL;
    PRINT '473 rollback: description edits cleared on adopted obligations = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
END
GO

SELECT '473 rollback: sp_resolve_obligation_list back on 457' AS Check_,
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_resolve_obligation_list')) NOT LIKE '%PublishedObligationDescription%'
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '473 rollback: completion gate back on 194',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_task_completion_eligibility')) NOT LIKE '%vw_pm_instance_evidence_cadence%'
            THEN 'PASS' ELSE 'FAIL' END;
GO
PRINT '473 rollback complete.';
GO
