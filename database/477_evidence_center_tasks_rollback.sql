-- =====================================================================
-- 477_evidence_center_tasks_rollback.sql
--
-- Reverses 477:
--   1. Hands task evidence back to task_attachment (192), so nothing
--      attached after 477 is lost: an active task link with no
--      task_attachment row (attached or linked after 477) gets one,
--      carrying the PINNED version's bytes.
--   2. Re-issues, verbatim, the bodies 477 replaced:
--        sp_task_attachment_add / sp_task_attachment_get   (193)
--        sp_task_get                                       (195)
--        sp_task_completion_eligibility                    (473)
--        fn_pm_evidence_item_visible, sp_evidence_center_get (476)
--   3. Drops the procedures, functions and the notice table 477 added.
--   4. Removes the task links, the items the 477 migration created that
--      are no longer linked anywhere (their files are still in
--      task_attachment), legacy_task_attachment_id, and puts the 476
--      target check back (InstanceEvidence only).
--   Items uploaded on a task after 477 stay in the Evidence Center (their
--   files were also copied back to the task in step 1).
--
-- Turn the API / Web change off first (or deploy the previous build).
-- SAFE TO RE-RUN. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET NOEXEC OFF;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

-- =====================================================================
-- 1. Task evidence back to task_attachment
-- =====================================================================
IF OBJECT_ID('grac_practice.evidence_link','U') IS NOT NULL
   AND COL_LENGTH('grac_practice.evidence_link','legacy_task_attachment_id') IS NOT NULL
BEGIN
    DECLARE @l_id BIGINT, @new_att BIGINT, @copied INT = 0;
    DECLARE rb477 CURSOR LOCAL FAST_FORWARD FOR
        SELECT l.evidence_link_id
        FROM   grac_practice.evidence_link l
        WHERE  l.target_type = N'Task'
          AND  l.status = N'Active'
          AND  l.legacy_task_attachment_id IS NULL
        ORDER  BY l.evidence_link_id;
    OPEN rb477;
    FETCH NEXT FROM rb477 INTO @l_id;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRAN;
        INSERT grac_practice.task_attachment
            (task_id, file_name, content_type, file_size_bytes, file_data,
             evidence_description, uploaded_by_employee_id, uploaded_dt)
        SELECT l.target_id, f.file_name, f.content_type, f.file_size_bytes, f.file_data,
               l.link_note, l.linked_by_employee_id, l.linked_dt
        FROM   grac_practice.evidence_link l
        JOIN   grac_practice.evidence_item_file f ON f.evidence_file_id = l.evidence_file_id
        WHERE  l.evidence_link_id = @l_id;
        SET @new_att = SCOPE_IDENTITY();
        UPDATE grac_practice.evidence_link SET legacy_task_attachment_id = @new_att
         WHERE evidence_link_id = @l_id;
        COMMIT;
        SET @copied = @copied + 1;
        FETCH NEXT FROM rb477 INTO @l_id;
    END
    CLOSE rb477;
    DEALLOCATE rb477;
    PRINT '477 rollback: files copied back to task_attachment = ' + CAST(@copied AS NVARCHAR(20));
END
GO

-- =====================================================================
-- 2. The replaced bodies
-- =====================================================================
-- 2a. sp_task_attachment_add (193 body)
CREATE OR ALTER PROCEDURE grac_practice.sp_task_attachment_add
    @task_id                 BIGINT,
    @file_name               NVARCHAR(500),
    @content_type            NVARCHAR(200)  = NULL,
    @file_data               VARBINARY(MAX),
    @evidence_description    NVARCHAR(1000) = NULL,
    @uploaded_by_employee_id BIGINT         = NULL,
    @caller_display_name     NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @task_id IS NULL
        THROW 55608, 'sp_task_attachment_add: task_id is required.', 1;
    IF @file_name IS NULL OR LEN(LTRIM(RTRIM(@file_name))) = 0
        THROW 55609, 'sp_task_attachment_add: file_name is required.', 1;
    IF @file_data IS NULL
        THROW 55610, 'sp_task_attachment_add: file_data is required.', 1;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.practice_task WHERE task_id = @task_id)
        THROW 55611, 'sp_task_attachment_add: task not found.', 1;

    DECLARE @size BIGINT = DATALENGTH(@file_data);

    BEGIN TRAN;

    INSERT INTO grac_practice.task_attachment
        (task_id, file_name, content_type, file_size_bytes, file_data,
         evidence_description, uploaded_by_employee_id, uploaded_dt)
    VALUES
        (@task_id, @file_name, @content_type, @size, @file_data,
         @evidence_description, @uploaded_by_employee_id, SYSUTCDATETIME());

    DECLARE @attachment_id BIGINT = SCOPE_IDENTITY();

    EXEC grac_practice.sp_task_activity_add
         @task_id             = @task_id,
         @activity_type_code  = N'EvidenceAdded',
         @remark              = @evidence_description,
         @to_value            = @file_name,
         @actor_employee_id   = @uploaded_by_employee_id,
         @caller_display_name = @caller_display_name;

    COMMIT;

    SELECT @attachment_id AS TaskAttachmentId, @size AS FileSizeBytes;
END;
GO

-- 2b. sp_task_attachment_get (193 body)
CREATE OR ALTER PROCEDURE grac_practice.sp_task_attachment_get
    @task_attachment_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    IF @task_attachment_id IS NULL
        THROW 55612, 'sp_task_attachment_get: task_attachment_id is required.', 1;

    SELECT a.task_attachment_id AS TaskAttachmentId,
           a.task_id            AS TaskId,
           a.file_name          AS FileName,
           a.content_type       AS ContentType,
           a.file_size_bytes    AS FileSizeBytes,
           a.file_data          AS FileData
      FROM grac_practice.task_attachment a
     WHERE a.task_attachment_id = @task_attachment_id;
END;
GO

-- 2c. sp_task_get (195 body)
CREATE OR ALTER PROCEDURE grac_practice.sp_task_get
    @task_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    IF @task_id IS NULL
        THROW 55700, 'sp_task_get: task_id is required.', 1;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.practice_task WHERE task_id = @task_id)
        THROW 55701, 'sp_task_get: task not found.', 1;

    -- ---- 1. Header --------------------------------------------------
    SELECT * FROM grac_practice.vw_pm_practice_task WHERE task_id = @task_id;

    -- ---- 2. Activity / update history -------------------------------
    SELECT a.task_activity_id   AS TaskActivityId,
           a.task_id            AS TaskId,
           a.activity_type_code AS ActivityTypeCode,
           a.remark             AS Remark,
           a.from_value         AS FromValue,
           a.to_value           AS ToValue,
           a.actor_employee_id  AS ActorEmployeeId,
           a.actor_display_name AS ActorDisplayName,
           a.entered_dt         AS EnteredDt
      FROM grac_practice.task_activity a
     WHERE a.task_id = @task_id
     ORDER BY a.entered_dt DESC, a.task_activity_id DESC;

    -- ---- 3. Evidence / attachments (metadata only) ------------------
    SELECT at.task_attachment_id   AS TaskAttachmentId,
           at.file_name            AS FileName,
           at.content_type         AS ContentType,
           at.file_size_bytes      AS FileSizeBytes,
           at.evidence_description AS EvidenceDescription,
           at.uploaded_by_employee_id AS UploadedByEmployeeId,
           e.employee_name         AS UploadedByName,
           at.uploaded_dt          AS UploadedDt
      FROM grac_practice.task_attachment at
 LEFT JOIN grac_practice.organization_employee e ON e.employee_id = at.uploaded_by_employee_id
     WHERE at.task_id = @task_id
     ORDER BY at.uploaded_dt DESC;

    -- ---- 4. Children -------------------------------------------------
    SELECT c.task_id                  AS TaskId,
           c.task_number              AS TaskNumber,
           c.subject_title            AS SubjectTitle,
           c.subject_description      AS SubjectDescription,
           c.assigned_to_employee_id  AS AssignedToEmployeeId,
           c.assigned_to_employee_name AS AssignedToEmployeeName,
           c.priority                 AS Priority,
           c.is_mandatory_child       AS IsMandatoryChild,
           c.child_target_date        AS ChildTargetDate,
           c.sla_due_at               AS SlaDueAt,
           c.sla_status_code          AS SlaStatusCode,
           c.current_status_code      AS CurrentStatusCode,
           c.current_status_name      AS CurrentStatusName,
           c.closed_at                AS ClosedAt,
           c.completed_dt             AS CompletedDt
      FROM grac_practice.vw_pm_practice_task c
     WHERE c.parent_task_id = @task_id
     ORDER BY c.is_mandatory_child DESC, c.task_id;

    -- ---- 5. Governance requests raised against this task -------------
    SELECT r.exception_request_id AS ExceptionRequestId,
           r.request_type_code    AS RequestTypeCode,
           r.request_title        AS RequestTitle,
           r.request_reason       AS RequestReason,
           r.status_code          AS StatusCode,
           r.priority_original    AS PriorityOriginal,
           r.priority_requested   AS PriorityRequested,
           r.due_at_original      AS DueAtOriginal,
           r.due_at_requested     AS DueAtRequested,
           r.requested_dt         AS RequestedOn,
           rq.employee_name       AS RequestedByName,
           r.approved_dt          AS ApprovedOn,
           ap.employee_name       AS ApprovedByName,
           r.rejected_dt          AS RejectedOn,
           rj.employee_name       AS RejectedByName,
           r.rejection_reason     AS RejectionReason
      FROM grac_practice.exception_request r
 LEFT JOIN grac_practice.organization_employee rq ON rq.employee_id = r.requested_by_employee_id
 LEFT JOIN grac_practice.organization_employee ap ON ap.employee_id = r.approved_by_employee_id
 LEFT JOIN grac_practice.organization_employee rj ON rj.employee_id = r.rejected_by_employee_id
     WHERE r.task_id = @task_id
     ORDER BY r.requested_dt DESC, r.exception_request_id DESC;
END;
GO

-- 2d. sp_task_completion_eligibility (473 body)
CREATE OR ALTER PROCEDURE grac_practice.sp_task_completion_eligibility
    @task_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    IF @task_id IS NULL
        THROW 55680, 'sp_task_completion_eligibility: task_id is required.', 1;

    DECLARE @closed_at DATETIME2, @exists BIT = 0,
            @source_type NVARCHAR(40), @source_record_id BIGINT;   -- 473
    SELECT @closed_at        = closed_at,
           @source_type      = source_type_code,
           @source_record_id = source_record_id,
           @exists           = 1
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

    -- 473: a task raised for a scheduled occurrence (449, source
    -- 'Schedule') whose obligation expects RECURRING evidence cannot be
    -- completed until evidence is attached to the task. One-time evidence
    -- is attached once, on Operationalize, and is not asked for again.
    DECLARE @recurring_count INT = 0, @recurring_names NVARCHAR(MAX) = NULL,
            @attachment_count INT = 0;
    IF @source_type = N'Schedule' AND @source_record_id IS NOT NULL
    BEGIN
        SELECT @recurring_count = COUNT(*),
               @recurring_names = STRING_AGG(CAST(COALESCE(NULLIF(LTRIM(RTRIM(pie.evidence_name)), N''),
                                                           get.evidence_type_name, N'Evidence')
                                                  AS NVARCHAR(MAX)), N', ')
          FROM grac_practice.schedule_occurrence_task x
          JOIN grac_practice.practice_instance_obligation pio
            ON pio.practice_instance_obligation_id = x.practice_instance_obligation_id
          JOIN grac_practice.practice_instance_evidence pie
            ON pie.practice_instance_id = x.practice_instance_id
           AND pie.status = N'Active'
           AND (   (pio.obligation_id IS NOT NULL AND pie.source_obligation_id = pio.obligation_id)
                OR pie.source_practice_instance_obligation_id = pio.practice_instance_obligation_id)
          JOIN grac_practice.vw_pm_instance_evidence_cadence c
            ON c.evidence_id = pie.evidence_id
          LEFT JOIN GRAC_New.evidence_type_master get
            ON get.evidence_type_id = pie.evidence_type_id
         WHERE x.occurrence_task_id = @source_record_id
           AND c.EvidenceCadence = N'Recurring';

        SELECT @attachment_count = COUNT(*)
          FROM grac_practice.task_attachment ta
         WHERE ta.task_id = @task_id;
    END

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
    ELSE IF @recurring_count > 0 AND @attachment_count = 0
    BEGIN
        SET @eligible = 0;
        SET @reason   = LEFT(CONCAT(N'Attach the evidence for this occurrence before completing it (recurring evidence: ',
                                    @recurring_names, N').'), 300);
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

-- 2e. fn_pm_evidence_item_visible (476 body)
CREATE OR ALTER FUNCTION grac_practice.fn_pm_evidence_item_visible
    (@evidence_item_id       BIGINT,
     @owner_employee_id      BIGINT,
     @created_by_employee_id BIGINT,
     @classification         NVARCHAR(30),
     @caller_employee_id     BIGINT,
     @caller_is_admin        BIT)
RETURNS TABLE
AS
RETURN
SELECT CAST(1 AS BIT) AS is_visible
WHERE  ISNULL(@caller_is_admin, 0) = 1
   OR (@caller_employee_id IS NOT NULL AND @owner_employee_id = @caller_employee_id)
   OR (ISNULL(@classification, N'Internal') <> N'Restricted'
       AND @caller_employee_id IS NOT NULL
       AND @created_by_employee_id = @caller_employee_id)
   OR (ISNULL(@classification, N'Internal') <> N'Restricted'
       AND EXISTS (SELECT 1
                   FROM   grac_practice.evidence_link l
                   JOIN   grac_practice.practice_instance pi
                          ON pi.practice_instance_id = l.practice_instance_id
                   WHERE  l.evidence_item_id = @evidence_item_id
                     AND  l.status = N'Active'));
GO

-- 2f. sp_evidence_center_get (476 body)
CREATE OR ALTER PROCEDURE grac_practice.sp_evidence_center_get
    @organization_id    BIGINT,
    @evidence_item_id   BIGINT,
    @caller_employee_id BIGINT = NULL,
    @caller_is_admin    BIT    = 0,
    @expiring_days      INT    = 30
AS
BEGIN
    SET NOCOUNT ON;

    IF @organization_id IS NULL OR @evidence_item_id IS NULL
        THROW 52781, 'Organization and evidence item are both required.', 1;
    SET @expiring_days = CASE WHEN ISNULL(@expiring_days, 0) < 1 THEN 30 ELSE @expiring_days END;

    DECLARE @today DATE = CONVERT(DATE, SYSUTCDATETIME());
    DECLARE @visible BIT = 0, @can_edit BIT = 0;

    SELECT @visible  = CASE WHEN v.is_visible = 1 THEN 1 ELSE 0 END,
           @can_edit = CASE WHEN ed.is_editable = 1 THEN 1 ELSE 0 END
    FROM   grac_practice.evidence_item i
    OUTER  APPLY grac_practice.fn_pm_evidence_item_visible(
               i.evidence_item_id, i.owner_employee_id, i.created_by_employee_id,
               i.classification, @caller_employee_id, @caller_is_admin) v
    OUTER  APPLY grac_practice.fn_pm_evidence_item_editable(
               i.owner_employee_id, i.created_by_employee_id,
               i.classification, @caller_employee_id, @caller_is_admin) ed
    WHERE  i.evidence_item_id = @evidence_item_id
      AND  i.organization_id  = @organization_id
      AND  i.status <> N'Deleted';

    DECLARE @total INT = 0, @seen INT = 0;
    IF @visible = 1
    BEGIN
        SELECT @total = COUNT(*) FROM grac_practice.evidence_link l
         WHERE l.evidence_item_id = @evidence_item_id AND l.status = N'Active';
        SELECT @seen = COUNT(*) FROM grac_practice.evidence_link l
          JOIN grac_practice.practice_instance pi ON pi.practice_instance_id = l.practice_instance_id
         WHERE l.evidence_item_id = @evidence_item_id AND l.status = N'Active';
    END

    -- 1. item
    SELECT i.evidence_item_id       AS EvidenceItemId,
           i.evidence_title         AS EvidenceTitle,
           i.evidence_type_id       AS EvidenceTypeId,
           et.evidence_type_name    AS EvidenceType,
           i.evidence_description   AS EvidenceDescription,
           i.owner_employee_id      AS OwnerEmployeeId,
           ow.employee_name         AS OwnerName,
           i.valid_from             AS ValidFrom,
           i.valid_to               AS ValidTo,
           CASE WHEN i.valid_to IS NULL THEN N'NoExpiry'
                WHEN i.valid_to < @today THEN N'Expired'
                WHEN i.valid_to <= DATEADD(DAY, @expiring_days, @today) THEN N'Expiring'
                ELSE N'Valid' END   AS ValidityState,
           i.classification         AS Classification,
           i.tags                   AS Tags,
           i.status                 AS Status,
           i.created_by_employee_id AS CreatedByEmployeeId,
           COALESCE(cr.employee_name, i.entered_by) AS CreatedByName,
           i.entered_dt             AS EnteredDt,
           i.updated_by             AS UpdatedBy,
           i.updated_dt             AS UpdatedDt,
           f.evidence_file_id       AS CurrentFileId,
           f.version_no             AS CurrentVersionNo,
           f.file_name              AS FileName,
           f.file_size_bytes        AS FileSizeBytes,
           @total                   AS UsedInCount,
           @total - @seen           AS HiddenUsageCount,
           @can_edit                AS CanEdit
    FROM   grac_practice.evidence_item i
    LEFT   JOIN grac_practice.evidence_type_master et ON et.evidence_type_id = i.evidence_type_id
    LEFT   JOIN grac_practice.organization_employee ow ON ow.employee_id = i.owner_employee_id
    LEFT   JOIN grac_practice.organization_employee cr ON cr.employee_id = i.created_by_employee_id
    LEFT   JOIN grac_practice.evidence_item_file f
           ON f.evidence_item_id = i.evidence_item_id AND f.is_current = 1
    WHERE  i.evidence_item_id = @evidence_item_id
      AND  @visible = 1;

    -- 2. versions
    SELECT f.evidence_file_id        AS EvidenceFileId,
           f.version_no              AS VersionNo,
           f.is_current              AS IsCurrent,
           f.file_name               AS FileName,
           f.content_type            AS ContentType,
           f.file_size_bytes         AS FileSizeBytes,
           f.version_note            AS VersionNote,
           f.uploaded_by_employee_id AS UploadedByEmployeeId,
           COALESCE(up.employee_name, f.uploaded_by) AS UploadedByName,
           f.uploaded_dt             AS UploadedDt,
           (SELECT COUNT(*) FROM grac_practice.evidence_link l
             WHERE l.evidence_file_id = f.evidence_file_id AND l.status = N'Active') AS PinnedLinkCount
    FROM   grac_practice.evidence_item_file f
    LEFT   JOIN grac_practice.organization_employee up ON up.employee_id = f.uploaded_by_employee_id
    WHERE  f.evidence_item_id = @evidence_item_id
      AND  @visible = 1
    ORDER  BY f.version_no DESC;

    -- 3. used in (visible instances only)
    SELECT l.evidence_link_id       AS EvidenceLinkId,
           l.target_type            AS TargetType,
           l.target_id              AS TargetId,
           l.practice_instance_id   AS PracticeInstanceId,
           pi.instance_code         AS InstanceCode,
           pi.instance_name         AS InstanceName,
           p.practice_id            AS PracticeId,
           p.practice_code          AS PracticeCode,
           p.practice_name          AS PracticeName,
           COALESCE(NULLIF(LTRIM(RTRIM(e.evidence_name)), N''), et.evidence_type_name) AS EvidenceName,
           f.version_no             AS PinnedVersionNo,
           CAST(f.is_current AS BIT) AS IsLatest,
           l.link_note              AS LinkNote,
           COALESCE(lb.employee_name, l.linked_by) AS LinkedByName,
           l.linked_dt              AS LinkedDt
    FROM   grac_practice.evidence_link l
    JOIN   grac_practice.practice_instance pi ON pi.practice_instance_id = l.practice_instance_id
    LEFT   JOIN grac_practice.practice p ON p.practice_id = pi.practice_id
    LEFT   JOIN grac_practice.practice_instance_evidence e
           ON l.target_type = N'InstanceEvidence' AND e.evidence_id = l.target_id
    LEFT   JOIN grac_practice.evidence_type_master et ON et.evidence_type_id = e.evidence_type_id
    JOIN   grac_practice.evidence_item_file f ON f.evidence_file_id = l.evidence_file_id
    LEFT   JOIN grac_practice.organization_employee lb ON lb.employee_id = l.linked_by_employee_id
    WHERE  l.evidence_item_id = @evidence_item_id
      AND  l.status = N'Active'
      AND  @visible = 1
    ORDER  BY p.practice_code, pi.instance_code, l.evidence_link_id;
END
GO

-- =====================================================================
-- 3. Objects 477 added
-- =====================================================================
DROP PROCEDURE IF EXISTS grac_practice.sp_task_evidence_candidates;
DROP PROCEDURE IF EXISTS grac_practice.sp_task_evidence_link_add;
DROP PROCEDURE IF EXISTS grac_practice.sp_evidence_expiry_sweep;
DROP PROCEDURE IF EXISTS grac_practice.sp_evidence_expiry_notice_list;
DROP PROCEDURE IF EXISTS grac_practice.sp_evidence_expiry_notice_mark;
GO
DROP FUNCTION IF EXISTS grac_practice.fn_pm_task_evidence_period;
GO
DROP TABLE IF EXISTS grac_practice.evidence_expiry_notice;
GO

-- =====================================================================
-- 4. Task links, migrated items, the column and the check
-- =====================================================================
IF OBJECT_ID('grac_practice.evidence_link','U') IS NOT NULL
BEGIN
    DELETE FROM grac_practice.evidence_link WHERE target_type = N'Task';
    PRINT '477 rollback: task links removed = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));

    -- Items the 477 migration created, now linked nowhere (their files
    -- are still in task_attachment).
    DECLARE @gone TABLE (evidence_item_id BIGINT PRIMARY KEY);
    INSERT @gone (evidence_item_id)
    SELECT DISTINCT i.evidence_item_id
    FROM   grac_practice.evidence_item i
    JOIN   grac_practice.practice_audit_trace t
           ON t.entity_type = N'evidence-item' AND t.entity_id = i.evidence_item_id
          AND t.action_type = N'MIGRATE' AND t.entered_by = N'migration-477'
    WHERE  NOT EXISTS (SELECT 1 FROM grac_practice.evidence_link l WHERE l.evidence_item_id = i.evidence_item_id);

    IF OBJECT_ID('grac_practice.evidence_expiry_notice','U') IS NOT NULL
        DELETE n FROM grac_practice.evidence_expiry_notice n JOIN @gone g ON g.evidence_item_id = n.evidence_item_id;
    DELETE f FROM grac_practice.evidence_item_file f JOIN @gone g ON g.evidence_item_id = f.evidence_item_id;
    DELETE i FROM grac_practice.evidence_item i JOIN @gone g ON g.evidence_item_id = i.evidence_item_id;
    PRINT '477 rollback: migrated task items removed = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
END
GO
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ux_pm_evidence_link_legacy_task'
            AND object_id = OBJECT_ID('grac_practice.evidence_link'))
    DROP INDEX ux_pm_evidence_link_legacy_task ON grac_practice.evidence_link;
GO
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ix_pm_evidence_link_target'
            AND object_id = OBJECT_ID('grac_practice.evidence_link'))
    DROP INDEX ix_pm_evidence_link_target ON grac_practice.evidence_link;
GO
IF OBJECT_ID('grac_practice.fk_pm_evidence_link_legacy_task','F') IS NOT NULL
    ALTER TABLE grac_practice.evidence_link DROP CONSTRAINT fk_pm_evidence_link_legacy_task;
GO
IF COL_LENGTH('grac_practice.evidence_link','legacy_task_attachment_id') IS NOT NULL
    ALTER TABLE grac_practice.evidence_link DROP COLUMN legacy_task_attachment_id;
GO
IF EXISTS (SELECT 1 FROM sys.check_constraints
            WHERE name = 'ck_pm_evidence_link_target'
              AND parent_object_id = OBJECT_ID('grac_practice.evidence_link')
              AND definition LIKE '%Task%')
BEGIN
    ALTER TABLE grac_practice.evidence_link DROP CONSTRAINT ck_pm_evidence_link_target;
    ALTER TABLE grac_practice.evidence_link WITH CHECK
        ADD CONSTRAINT ck_pm_evidence_link_target CHECK (target_type IN (N'InstanceEvidence'));
    PRINT '477 rollback: ck_pm_evidence_link_target = InstanceEvidence.';
END
GO

-- =====================================================================
-- Verification
-- =====================================================================
SELECT '477 rollback: task procedures read task_attachment' AS Check_,
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_task_get')) LIKE '%task_attachment at%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_task_attachment_get')) NOT LIKE '%evidence_link%'
             AND OBJECT_ID('grac_practice.sp_task_evidence_link_add','P') IS NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result_;
GO
PRINT '477 rollback complete.';
GO
