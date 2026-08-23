-- =====================================================================
-- 132 Event Assurance -- execute obligation instances
--
-- SYMPTOM
-- -------
-- The inbox shows an obligation pack with progress 0 / 1, but opening it
-- shows an empty item table.
--
-- CAUSE
-- -----
-- sp_event_instance_detail_get reads event_instance_item only. Obligation
-- instances keep their line items in event_instance_obligation (127), so the
-- header and the count were right and the item list was empty.
--
-- SEPARATE AND MORE SERIOUS: sp_event_instance_complete evaluated its
-- mandatory-items gate against event_instance_item too. For an obligation
-- instance that EXISTS check finds nothing, so "no unfinished mandatory
-- item" was trivially true and the instance would close as Completed with
-- every obligation still Pending. An onboarding pack could be signed off
-- with nothing done. That is fixed here.
--
-- WHY ItemOrigin RATHER THAN MERGING THE IDs
-- ------------------------------------------
-- Both item tables are IDENTITY, so event_instance_item_id 42 and
-- event_instance_obligation_id 42 can both exist. The submit endpoint takes
-- an item id, so a merged list would eventually write the wrong row. The
-- detail result therefore carries an explicit ItemOrigin discriminator and
-- the caller posts it back. The alternative -- negative ids for one side --
-- works but hides the distinction in a sign bit, which is exactly the kind
-- of cleverness that produces a silent wrong-row update in an audited system.
--
-- Procedures:
--   sp_event_instance_detail_get       ALTERED -- both item stores + ItemOrigin
--   sp_event_instance_obligation_save  NEW     -- record one obligation result
--   sp_event_instance_complete         ALTERED -- gate on both item stores
--
-- ERROR CODES: 67400-67499.
--
-- Depends on 124, 127, 128, 131.
-- Rollback: 132_event_instance_obligation_execution_rollback.sql.
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.event_instance_obligation','U') IS NULL
BEGIN
    RAISERROR('132: run 127 first.', 16, 1);
    RETURN;
END
GO


-- =====================================================================
-- sp_event_instance_detail_get -- header + items from BOTH stores
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_event_instance_detail_get
    @organization_id   BIGINT,
    @event_instance_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM grac_practice.event_instance
                    WHERE event_instance_id = @event_instance_id
                      AND organization_id   = @organization_id)
        THROW 67260, 'sp_event_instance_detail_get: instance not found for this organization.', 1;

    -- ---------- result set 1: header ----------
    SELECT
        ei.event_instance_id           AS EventInstanceId,
        ed.event_code                  AS EventCode,
        ed.event_name                  AS EventName,
        ei.subject_entity              AS SubjectEntity,
        ei.subject_record_id           AS SubjectRecordId,
        ei.entity_display_name         AS SubjectLabel,
        ei.scope_role_id               AS ScopeRoleId,
        ei.scope_role_name             AS ScopeRoleName,
        ei.scope_asset_category_id     AS ScopeAssetCategoryId,
        ei.scope_asset_category_name   AS ScopeAssetCategoryName,
        ei.release_id                  AS ReleaseId,
        ei.source_mapping_id           AS SourceMappingId,
        ei.checklist_id                AS ChecklistId,
        COALESCE(c.checklist_name,
                 CASE WHEN ei.origin_kind = N'OBLIGATION'
                      THEN N'Obligations (' + ei.event_type_code + N')' END) AS ChecklistName,
        c.version                      AS ChecklistVersion,
        ei.owner_employee_id           AS OwnerEmployeeId,
        oe.employee_name               AS OwnerEmployeeName,
        ei.effective_date              AS EffectiveDate,
        ei.due_date                    AS DueDate,
        ei.status                      AS InstanceStatus,
        ei.completed_dt                AS CompletedDt,
        ei.comments                    AS Comments
    FROM       grac_practice.event_instance ei
    JOIN       grac_practice.event_definition ed ON ed.event_definition_id = ei.event_definition_id
    LEFT JOIN  grac_practice.checklist c ON c.checklist_id = ei.checklist_id
    LEFT JOIN  grac_practice.organization_employee oe ON oe.employee_id = ei.owner_employee_id
    WHERE      ei.event_instance_id = @event_instance_id;

    -- ---------- result set 2: items, both stores ----------
    -- Same column shape from both branches so one mapper handles both;
    -- ItemOrigin tells the caller which table to write back to.
    SELECT * FROM (
        SELECT
            N'CHECKLIST'                AS ItemOrigin,
            ii.event_instance_item_id   AS ItemId,
            ci.checklist_item_id        AS SourceId,
            ci.item_sequence            AS ItemSequence,
            ci.item_text                AS ItemText,
            ci.item_type                AS ItemType,
            ci.is_mandatory             AS IsMandatory,
            ci.evidence_required        AS EvidenceRequired,
            ci.attachment_required      AS AttachmentRequired,
            ci.approval_required        AS ApprovalRequired,
            ci.responsible_role         AS ResponsibleRole,
            ii.item_status              AS ItemStatus,
            ii.evidence_url             AS EvidenceUrl,
            ii.remarks                  AS Remarks,
            CAST(NULL AS NVARCHAR(2000)) AS NaJustification,
            ii.completed_by             AS CompletedBy,
            ii.completed_dt             AS CompletedDt
        FROM   grac_practice.event_instance_item ii
        JOIN   grac_practice.checklist_item ci ON ci.checklist_item_id = ii.checklist_item_id
        WHERE  ii.event_instance_id = @event_instance_id

        UNION ALL

        SELECT
            N'OBLIGATION'                       AS ItemOrigin,
            io.event_instance_obligation_id      AS ItemId,
            io.obligation_id                     AS SourceId,
            io.item_sequence                     AS ItemSequence,
            -- obligation_text is the full requirement wording; the label is a
            -- short name. Show the label, fall back to the wording.
            COALESCE(NULLIF(LTRIM(RTRIM(io.obligation_label)), N''),
                     LEFT(io.obligation_text, 500),
                     CONCAT(N'Obligation #', io.obligation_id)) AS ItemText,
            N'Obligation'                        AS ItemType,
            io.is_mandatory                      AS IsMandatory,
            io.evidence_required                 AS EvidenceRequired,
            CAST(0 AS BIT)                       AS AttachmentRequired,
            CAST(0 AS BIT)                       AS ApprovalRequired,
            r.role_name                          AS ResponsibleRole,
            io.item_status                        AS ItemStatus,
            io.evidence_url                       AS EvidenceUrl,
            io.remarks                            AS Remarks,
            io.na_justification                   AS NaJustification,
            io.completed_by                       AS CompletedBy,
            io.completed_dt                       AS CompletedDt
        FROM       grac_practice.event_instance_obligation io
        LEFT JOIN  grac_practice.event_obligation_applicability a
               ON  a.applicability_id = io.applicability_id
        LEFT JOIN  grac_practice.organization_role r
               ON  r.role_id = a.owner_role_id
        WHERE      io.event_instance_id = @event_instance_id
    ) items
    ORDER BY ItemOrigin, ItemSequence, ItemId;
END;
GO


-- =====================================================================
-- sp_event_instance_obligation_save -- record one obligation result
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_event_instance_obligation_save
    @organization_id             BIGINT,
    @event_instance_obligation_id BIGINT,
    @item_status                 NVARCHAR(30),
    @evidence_url                NVARCHAR(1000) = NULL,
    @remarks                     NVARCHAR(MAX)  = NULL,
    @na_justification            NVARCHAR(2000) = NULL,
    @actor_employee_id           BIGINT         = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @item_status NOT IN (N'Pending', N'Passed', N'Failed', N'NotApplicable', N'InProgress')
        THROW 67400, 'sp_event_instance_obligation_save: invalid item_status.', 1;

    DECLARE @inst BIGINT, @org BIGINT, @evidence_required BIT, @inst_status NVARCHAR(30);
    SELECT @inst = io.event_instance_id, @org = io.organization_id,
           @evidence_required = io.evidence_required, @inst_status = ei.status
    FROM   grac_practice.event_instance_obligation io
    JOIN   grac_practice.event_instance ei ON ei.event_instance_id = io.event_instance_id
    WHERE  io.event_instance_obligation_id = @event_instance_obligation_id;

    IF @inst IS NULL
        THROW 67401, 'sp_event_instance_obligation_save: obligation row not found.', 1;
    IF @org <> @organization_id
        THROW 67402, 'sp_event_instance_obligation_save: row belongs to a different organization.', 1;

    -- A closed instance is a record, not a workspace. Reopening is a separate
    -- deliberate action, not a side effect of editing a line.
    IF @inst_status IN (N'Completed', N'Cancelled')
        THROW 67403, 'sp_event_instance_obligation_save: the instance is already closed.', 1;

    -- Same rule as the mapping screen and the schema CHECK: an exclusion
    -- without a reason is not auditable.
    IF @item_status = N'NotApplicable'
       AND (@na_justification IS NULL OR LEN(LTRIM(RTRIM(@na_justification))) = 0)
        THROW 67404, 'sp_event_instance_obligation_save: a justification is required to mark an obligation Not Applicable.', 1;

    IF @item_status = N'Passed' AND @evidence_required = 1
       AND (@evidence_url IS NULL OR LEN(LTRIM(RTRIM(@evidence_url))) = 0)
        THROW 67405, 'sp_event_instance_obligation_save: this obligation requires evidence before it can be passed.', 1;

    DECLARE @actor NVARCHAR(100) = COALESCE(CAST(@actor_employee_id AS NVARCHAR(100)), 'api');

    UPDATE grac_practice.event_instance_obligation
       SET item_status      = @item_status,
           evidence_url     = @evidence_url,
           remarks          = @remarks,
           na_justification = CASE WHEN @item_status = N'NotApplicable' THEN @na_justification ELSE NULL END,
           completed_by     = CASE WHEN @item_status IN (N'Passed', N'Failed', N'NotApplicable')
                                   THEN @actor ELSE NULL END,
           completed_dt     = CASE WHEN @item_status IN (N'Passed', N'Failed', N'NotApplicable')
                                   THEN SYSUTCDATETIME() ELSE NULL END,
           updated_by       = @actor,
           updated_dt       = SYSUTCDATETIME()
     WHERE event_instance_obligation_id = @event_instance_obligation_id;

    -- First result recorded moves the pack out of Pending, so the inbox
    -- distinguishes "nobody has started" from "someone is working on it".
    UPDATE grac_practice.event_instance
       SET status     = N'InProgress',
           updated_by = @actor,
           updated_dt = SYSUTCDATETIME()
     WHERE event_instance_id = @inst
       AND status = N'Pending'
       AND @item_status <> N'Pending';

    INSERT INTO grac_practice.event_audit
        (organization_id, event_instance_id, entity_type, entity_id,
         action, actor, new_value, entered_dt)
    VALUES
        (@organization_id, @inst, N'EventInstance', @event_instance_obligation_id,
         N'Update', @actor,
         CONCAT(N'obligation_row=', @event_instance_obligation_id, N';status=', @item_status),
         SYSUTCDATETIME());
END;
GO


-- =====================================================================
-- sp_event_instance_complete -- gate on BOTH item stores
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_event_instance_complete
    @event_instance_id BIGINT,
    @actor_employee_id BIGINT       = NULL,
    @comments          NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NOT EXISTS (SELECT 1 FROM grac_practice.event_instance WHERE event_instance_id = @event_instance_id)
        THROW 67090, 'sp_event_instance_complete: event_instance_id not found.', 1;

    DECLARE @actor NVARCHAR(100) = COALESCE(CAST(@actor_employee_id AS NVARCHAR(100)), 'api');

    -- An instance with no line items at all cannot be "complete" -- it has
    -- nothing to attest to. Before 132 an obligation pack fell into exactly
    -- this hole and closed as Completed with everything still Pending.
    DECLARE @item_total INT =
        (SELECT COUNT(*) FROM grac_practice.event_instance_item WHERE event_instance_id = @event_instance_id)
      + (SELECT COUNT(*) FROM grac_practice.event_instance_obligation WHERE event_instance_id = @event_instance_id);

    IF @item_total = 0
        THROW 67406, 'sp_event_instance_complete: the instance has no items to complete.', 1;

    -- Mandatory items still unresolved -> block, rather than silently
    -- recording a Failed close. The caller shows which ones are outstanding.
    DECLARE @unresolved INT =
        (SELECT COUNT(*)
         FROM   grac_practice.event_instance_item ii
         JOIN   grac_practice.checklist_item ci ON ci.checklist_item_id = ii.checklist_item_id
         WHERE  ii.event_instance_id = @event_instance_id
           AND  ci.is_mandatory = 1
           AND  ii.item_status NOT IN (N'Passed', N'Failed', N'NotApplicable'))
      + (SELECT COUNT(*)
         FROM   grac_practice.event_instance_obligation io
         WHERE  io.event_instance_id = @event_instance_id
           AND  io.is_mandatory = 1
           AND  io.item_status NOT IN (N'Passed', N'Failed', N'NotApplicable'));

    IF @unresolved > 0
        THROW 67407, 'sp_event_instance_complete: mandatory items are still unresolved.', 1;

    -- Resolved, but any mandatory item that FAILED makes the event Failed.
    -- NotApplicable is a documented judgement and does not fail the event.
    DECLARE @has_failure BIT =
        CASE WHEN EXISTS (
                 SELECT 1
                 FROM   grac_practice.event_instance_item ii
                 JOIN   grac_practice.checklist_item ci ON ci.checklist_item_id = ii.checklist_item_id
                 WHERE  ii.event_instance_id = @event_instance_id
                   AND  ci.is_mandatory = 1 AND ii.item_status = N'Failed')
              OR EXISTS (
                 SELECT 1
                 FROM   grac_practice.event_instance_obligation io
                 WHERE  io.event_instance_id = @event_instance_id
                   AND  io.is_mandatory = 1 AND io.item_status = N'Failed')
             THEN 1 ELSE 0 END;

    UPDATE grac_practice.event_instance
       SET status       = CASE WHEN @has_failure = 1 THEN N'Failed' ELSE N'Completed' END,
           completed_dt = SYSUTCDATETIME(),
           comments     = COALESCE(@comments, comments),
           updated_by   = @actor,
           updated_dt   = SYSUTCDATETIME()
     WHERE event_instance_id = @event_instance_id;

    INSERT INTO grac_practice.event_audit
        (organization_id, event_instance_id, entity_type, entity_id,
         action, actor, new_value, entered_dt)
    SELECT organization_id, event_instance_id, N'EventInstance', event_instance_id,
           N'Complete', @actor,
           CONCAT(N'items=', @item_total, N';failed=', @has_failure),
           SYSUTCDATETIME()
    FROM   grac_practice.event_instance WHERE event_instance_id = @event_instance_id;
END;
GO


-- =====================================================================
-- Sanity report
-- =====================================================================
SELECT 'sp_event_instance_detail_get'      AS Check_, CASE WHEN OBJECT_ID('grac_practice.sp_event_instance_detail_get','P')      IS NOT NULL THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL SELECT 'sp_event_instance_obligation_save', CASE WHEN OBJECT_ID('grac_practice.sp_event_instance_obligation_save','P') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT 'sp_event_instance_complete',        CASE WHEN OBJECT_ID('grac_practice.sp_event_instance_complete','P')        IS NOT NULL THEN 'PASS' ELSE 'FAIL' END;

-- Instances that closed as Completed while items were still Pending -- the
-- damage the old complete gate could do. Review these; they were signed off
-- without the work being recorded.
PRINT '--- Suspicious closures (Completed with unresolved mandatory items) ---';
SELECT ei.event_instance_id, ei.organization_id, ei.origin_kind,
       ei.entity_display_name AS SubjectLabel, ei.status, ei.completed_dt,
       (SELECT COUNT(*) FROM grac_practice.event_instance_obligation io
         WHERE io.event_instance_id = ei.event_instance_id
           AND io.is_mandatory = 1
           AND io.item_status NOT IN (N'Passed', N'Failed', N'NotApplicable')) AS UnresolvedObligations
FROM   grac_practice.event_instance ei
WHERE  ei.status = N'Completed'
  AND  EXISTS (SELECT 1 FROM grac_practice.event_instance_obligation io
                WHERE io.event_instance_id = ei.event_instance_id
                  AND io.is_mandatory = 1
                  AND io.item_status NOT IN (N'Passed', N'Failed', N'NotApplicable'))
ORDER BY ei.completed_dt DESC;

PRINT '132 Obligation instance execution deployed.';
GO
