-- =====================================================================
-- 482_task_recurring_evidence_rollback.sql
--
-- Reverses 482:
--   1. Re-issues, verbatim, the 477 bodies of sp_task_attachment_add,
--      sp_task_evidence_link_add, sp_task_get and
--      sp_task_completion_eligibility (the recurring-evidence gate comes
--      back).
--   2. Drops sp_task_recurring_evidence_list, sp_task_evidence_response_save
--      and fn_pm_task_recurring_evidence.
--   3. Drops practice_task_evidence_response only when it is empty;
--      otherwise keeps it and says so.
--   4. Drops evidence_link.instance_evidence_id (links stay on their task
--      as general task evidence).
-- Deploy the previous API / Web build first.
-- SAFE TO RE-RUN. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
GO

-- =====================================================================
-- 1. 477 bodies, verbatim
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_task_attachment_add
    @task_id                 BIGINT,
    @file_name               NVARCHAR(500),
    @content_type            NVARCHAR(200)  = NULL,
    @file_data               VARBINARY(MAX),
    @evidence_description    NVARCHAR(1000) = NULL,
    @uploaded_by_employee_id BIGINT         = NULL,
    @caller_display_name     NVARCHAR(100)  = N'system',
    @caller_is_admin         BIT            = 0       -- 477
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

    DECLARE @organization_id BIGINT, @instance_id BIGINT;
    SELECT @organization_id = t.organization_id, @instance_id = t.linked_instance_id
    FROM   grac_practice.practice_task t WHERE t.task_id = @task_id;
    IF @organization_id IS NULL
        THROW 55611, 'sp_task_attachment_add: task not found.', 1;

    IF @uploaded_by_employee_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee oe
                        WHERE oe.employee_id = @uploaded_by_employee_id
                          AND oe.organization_id = @organization_id)
        SET @uploaded_by_employee_id = NULL;

    SET @caller_display_name = ISNULL(NULLIF(LTRIM(RTRIM(@caller_display_name)), N''), N'system');

    DECLARE @size   BIGINT        = DATALENGTH(@file_data);
    DECLARE @hash   VARBINARY(32) = HASHBYTES('SHA2_256', @file_data);
    DECLARE @period DATE = (SELECT period_date FROM grac_practice.fn_pm_task_evidence_period(@task_id));
    DECLARE @item_id BIGINT, @file_id BIGINT, @version_no INT, @title NVARCHAR(300), @link_id BIGINT,
            @reused BIT = 0;

    -- The identical file, already in the Evidence Center, visible to the
    -- uploader and valid for this task's period.
    SELECT TOP 1 @item_id = i.evidence_item_id, @file_id = f.evidence_file_id,
                 @version_no = f.version_no, @title = i.evidence_title
    FROM   grac_practice.evidence_item_file f
    JOIN   grac_practice.evidence_item i ON i.evidence_item_id = f.evidence_item_id
    CROSS  APPLY grac_practice.fn_pm_evidence_item_visible(
               i.evidence_item_id, i.owner_employee_id, i.created_by_employee_id,
               i.classification, @uploaded_by_employee_id, @caller_is_admin) v
    WHERE  f.organization_id = @organization_id
      AND  f.file_sha256 = @hash
      AND  f.is_current = 1
      AND  i.status = N'Active'
      AND  (i.valid_from IS NULL OR i.valid_from <= @period)
      AND  (i.valid_to   IS NULL OR i.valid_to   >= @period)
    ORDER  BY i.evidence_item_id;

    IF @item_id IS NOT NULL
    BEGIN
        SET @reused = 1;
        SELECT @link_id = l.evidence_link_id
        FROM   grac_practice.evidence_link l
        WHERE  l.target_type = N'Task' AND l.target_id = @task_id
          AND  l.evidence_item_id = @item_id AND l.status = N'Active';
        IF @link_id IS NOT NULL
        BEGIN
            SELECT @link_id AS TaskAttachmentId, @size AS FileSizeBytes, @item_id AS EvidenceItemId,
                   CAST(1 AS BIT) AS Reused, N'This file is already attached to this task.' AS Message;
            RETURN;
        END
    END

    BEGIN TRAN;

    IF @item_id IS NULL
        EXEC grac_practice.sp_evidence_item_store
             @organization_id = @organization_id, @evidence_item_id = @item_id OUTPUT,
             @file_name = @file_name, @content_type = @content_type, @file_data = @file_data,
             @file_sha256 = @hash, @owner_employee_id = @uploaded_by_employee_id,
             @classification = N'Internal', @caller_employee_id = @uploaded_by_employee_id,
             @actor = @caller_display_name,
             @evidence_file_id = @file_id OUTPUT, @version_no = @version_no OUTPUT;

    INSERT grac_practice.evidence_link
        (organization_id, evidence_item_id, evidence_file_id, target_type, target_id,
         practice_instance_id, link_note, period_from, period_to, status,
         linked_by_employee_id, linked_by, linked_dt)
    VALUES
        (@organization_id, @item_id, @file_id, N'Task', @task_id,
         @instance_id, NULLIF(LTRIM(RTRIM(@evidence_description)), N''), @period, @period, N'Active',
         @uploaded_by_employee_id, @caller_display_name, SYSUTCDATETIME());
    SET @link_id = SCOPE_IDENTITY();

    EXEC grac_practice.sp_task_activity_add
         @task_id             = @task_id,
         @activity_type_code  = N'EvidenceAdded',
         @remark              = @evidence_description,
         @to_value            = @file_name,
         @actor_employee_id   = @uploaded_by_employee_id,
         @caller_display_name = @caller_display_name;

    INSERT grac_practice.practice_audit_trace(entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    SELECT N'evidence-link', @link_id, N'CREATE', NULL,
           (SELECT @item_id AS evidenceItemId, @version_no AS versionNo, @task_id AS taskId,
                   @period AS periodDate, @reused AS reusedIdenticalFile,
                   LTRIM(RTRIM(@file_name)) AS fileName, @size AS fileSizeBytes
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
           N'Active', @caller_display_name;

    COMMIT;

    SELECT @link_id AS TaskAttachmentId, @size AS FileSizeBytes, @item_id AS EvidenceItemId,
           @reused AS Reused,
           CASE WHEN @reused = 1
                THEN N'This file is already in the Evidence Center as "' + @title + N'" (version '
                     + CAST(@version_no AS NVARCHAR(10)) + N'). It was linked instead of stored again.'
                ELSE N'Evidence attached. It is also in the Evidence Center for reuse.' END AS Message;
END
GO


CREATE OR ALTER PROCEDURE grac_practice.sp_task_evidence_link_add
    @task_id             BIGINT,
    @organization_id     BIGINT,
    @evidence_item_id    BIGINT,
    @link_note           NVARCHAR(1000) = NULL,
    @caller_employee_id  BIGINT         = NULL,
    @caller_is_admin     BIT            = 0,
    @caller_display_name NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @task_id IS NULL OR @organization_id IS NULL OR @evidence_item_id IS NULL
        THROW 52862, 'Organization, task and evidence item are all required.', 1;

    DECLARE @closed_at DATETIME2, @instance_id BIGINT, @found BIT = 0;
    SELECT @found = 1, @closed_at = t.closed_at, @instance_id = t.linked_instance_id
    FROM   grac_practice.practice_task t
    WHERE  t.task_id = @task_id AND t.organization_id = @organization_id;

    IF @found = 0
        THROW 52861, 'That task was not found in this organization.', 1;
    IF @closed_at IS NOT NULL
        THROW 52863, 'This task is already completed. Evidence can no longer be added to it.', 1;

    IF @caller_employee_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee oe
                        WHERE oe.employee_id = @caller_employee_id
                          AND oe.organization_id = @organization_id)
        SET @caller_employee_id = NULL;

    DECLARE @period DATE = (SELECT period_date FROM grac_practice.fn_pm_task_evidence_period(@task_id));

    DECLARE @status NVARCHAR(30), @visible BIT = 0, @valid_from DATE, @valid_to DATE, @title NVARCHAR(300);
    SELECT @status = i.status, @valid_from = i.valid_from, @valid_to = i.valid_to, @title = i.evidence_title,
           @visible = CASE WHEN v.is_visible = 1 THEN 1 ELSE 0 END
    FROM   grac_practice.evidence_item i
    OUTER  APPLY grac_practice.fn_pm_evidence_item_visible(
               i.evidence_item_id, i.owner_employee_id, i.created_by_employee_id,
               i.classification, @caller_employee_id, @caller_is_admin) v
    WHERE  i.evidence_item_id = @evidence_item_id
      AND  i.organization_id  = @organization_id
      AND  i.status <> N'Deleted';

    IF @status IS NULL OR @visible = 0
        THROW 52784, 'That evidence item was not found in this organization.', 1;
    IF @status <> N'Active'
        THROW 52853, 'This evidence item is retired and cannot be linked.', 1;
    IF (@valid_from IS NOT NULL AND @valid_from > @period) OR (@valid_to IS NOT NULL AND @valid_to < @period)
    BEGIN
        DECLARE @msg NVARCHAR(400) = N'This evidence is not valid on ' + CONVERT(NVARCHAR(10), @period, 23)
            + N', the period of this task (valid ' + ISNULL(CONVERT(NVARCHAR(10), @valid_from, 23), N'...')
            + N' to ' + ISNULL(CONVERT(NVARCHAR(10), @valid_to, 23), N'...')
            + N'). Upload evidence for this period instead.';
        THROW 52864, @msg, 1;
    END
    IF EXISTS (SELECT 1 FROM grac_practice.evidence_link l
                WHERE l.target_type = N'Task' AND l.target_id = @task_id
                  AND l.evidence_item_id = @evidence_item_id AND l.status = N'Active')
        THROW 52865, 'This evidence item is already attached to this task.', 1;

    DECLARE @file_id BIGINT, @version_no INT;
    SELECT @file_id = f.evidence_file_id, @version_no = f.version_no
    FROM   grac_practice.evidence_item_file f
    WHERE  f.evidence_item_id = @evidence_item_id AND f.is_current = 1;
    IF @file_id IS NULL
        THROW 52856, 'This evidence item has no file.', 1;

    SET @caller_display_name = ISNULL(NULLIF(LTRIM(RTRIM(@caller_display_name)), N''), N'system');
    DECLARE @link_id BIGINT;
    DECLARE @label NVARCHAR(400) = LEFT(@title + N' (v' + CAST(@version_no AS NVARCHAR(10)) + N')', 400);

    BEGIN TRAN;

    INSERT grac_practice.evidence_link
        (organization_id, evidence_item_id, evidence_file_id, target_type, target_id,
         practice_instance_id, link_note, period_from, period_to, status,
         linked_by_employee_id, linked_by, linked_dt)
    VALUES
        (@organization_id, @evidence_item_id, @file_id, N'Task', @task_id,
         @instance_id, NULLIF(LTRIM(RTRIM(@link_note)), N''), @period, @period, N'Active',
         @caller_employee_id, @caller_display_name, SYSUTCDATETIME());
    SET @link_id = SCOPE_IDENTITY();

    -- Same activity the upload records, so the task's feed reads the same.
    EXEC grac_practice.sp_task_activity_add
         @task_id             = @task_id,
         @activity_type_code  = N'EvidenceAdded',
         @remark              = @link_note,
         @to_value            = @label,
         @actor_employee_id   = @caller_employee_id,
         @caller_display_name = @caller_display_name;

    INSERT grac_practice.practice_audit_trace(entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    SELECT N'evidence-link', @link_id, N'CREATE', NULL,
           (SELECT @evidence_item_id AS evidenceItemId, @version_no AS versionNo,
                   @task_id AS taskId, @period AS periodDate
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
           N'Active', @caller_display_name;

    COMMIT;

    SELECT @link_id AS TaskAttachmentId, @evidence_item_id AS EvidenceItemId, @version_no AS VersionNo,
           N'Linked "' + @title + N'" (version ' + CAST(@version_no AS NVARCHAR(10)) + N').' AS Message;
END
GO


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
    -- 477: Evidence Center links of this task. TaskAttachmentId is the
    -- link id; the file is the version the link is pinned to; UploadedDt
    -- is when it was attached to this task (the item's upload date is
    -- FileUploadedDt). Same first eight columns as 195.
    SELECT l.evidence_link_id      AS TaskAttachmentId,
           f.file_name             AS FileName,
           f.content_type          AS ContentType,
           f.file_size_bytes       AS FileSizeBytes,
           l.link_note             AS EvidenceDescription,
           l.linked_by_employee_id AS UploadedByEmployeeId,
           COALESCE(e.employee_name, l.linked_by) AS UploadedByName,
           l.linked_dt             AS UploadedDt,
           l.evidence_item_id      AS EvidenceItemId,
           i.evidence_title        AS EvidenceTitle,
           f.version_no            AS VersionNo,
           l.period_from           AS PeriodDate,
           f.uploaded_dt           AS FileUploadedDt
      FROM grac_practice.evidence_link l
      JOIN grac_practice.evidence_item_file f ON f.evidence_file_id = l.evidence_file_id
      JOIN grac_practice.evidence_item i      ON i.evidence_item_id = l.evidence_item_id
 LEFT JOIN grac_practice.organization_employee e ON e.employee_id = l.linked_by_employee_id
     WHERE l.target_type = N'Task'
       AND l.target_id = @task_id
       AND l.status = N'Active'
     ORDER BY l.linked_dt DESC, l.evidence_link_id DESC;

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

        -- 477: evidence on a task is an Evidence Center link.
        SELECT @attachment_count = COUNT(*)
          FROM grac_practice.evidence_link ta
         WHERE ta.target_type = N'Task'
           AND ta.target_id = @task_id
           AND ta.status = N'Active';
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


-- =====================================================================
-- 2. New objects
-- =====================================================================
IF OBJECT_ID('grac_practice.sp_task_recurring_evidence_list','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_task_recurring_evidence_list;
IF OBJECT_ID('grac_practice.sp_task_evidence_response_save','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_task_evidence_response_save;
IF OBJECT_ID('grac_practice.fn_pm_task_recurring_evidence') IS NOT NULL
    DROP FUNCTION grac_practice.fn_pm_task_recurring_evidence;
GO

-- =====================================================================
-- 3. practice_task_evidence_response -- only when empty
-- =====================================================================
IF OBJECT_ID('grac_practice.practice_task_evidence_response','U') IS NOT NULL
BEGIN
    IF NOT EXISTS (SELECT 1 FROM grac_practice.practice_task_evidence_response)
    BEGIN
        DROP TABLE grac_practice.practice_task_evidence_response;
        PRINT '482 rollback: practice_task_evidence_response dropped (it was empty).';
    END
    ELSE
        PRINT '482 rollback: practice_task_evidence_response KEPT -- it holds recorded evidence choices. Drop it by hand if they are not needed.';
END
GO

-- =====================================================================
-- 4. evidence_link.instance_evidence_id
-- =====================================================================
IF EXISTS (SELECT 1 FROM sys.indexes
            WHERE name = 'ix_pm_evidence_link_instance_evidence'
              AND object_id = OBJECT_ID('grac_practice.evidence_link'))
    DROP INDEX ix_pm_evidence_link_instance_evidence ON grac_practice.evidence_link;
GO
IF EXISTS (SELECT 1 FROM sys.foreign_keys
            WHERE name = 'fk_pm_evidence_link_instance_evidence'
              AND parent_object_id = OBJECT_ID('grac_practice.evidence_link'))
    ALTER TABLE grac_practice.evidence_link DROP CONSTRAINT fk_pm_evidence_link_instance_evidence;
GO
IF COL_LENGTH('grac_practice.evidence_link','instance_evidence_id') IS NOT NULL
    ALTER TABLE grac_practice.evidence_link DROP COLUMN instance_evidence_id;
GO

SELECT '482 rollback' AS Check_,
       CASE WHEN COL_LENGTH('grac_practice.evidence_link','instance_evidence_id') IS NULL
             AND OBJECT_ID('grac_practice.fn_pm_task_recurring_evidence') IS NULL
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_task_completion_eligibility')) LIKE '%@recurring_count%'
            THEN 'PASS' ELSE 'FAIL' END AS Result_;
PRINT '482 rollback complete.';
GO
