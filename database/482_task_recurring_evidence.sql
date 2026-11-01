-- =====================================================================
-- 482 Scheduled task: recurring evidence on Complete Task
--
-- Change request 2026-10-23 (sir). 481 took recurring evidence off
-- Operationalize. It is now asked for where it is produced: the Complete
-- Task dialog of the instance's scheduled task (449, source 'Schedule').
--   * Every RECURRING evidence row of the task's obligation is listed.
--   * Each row asks how the evidence is provided -- Direct Upload,
--     Evidence Center Reference or External Evidence Reference (the same
--     three options as 481) -- and shows only that option's control.
--   * Nothing is mandatory: the 473 gate ("attach the evidence for this
--     occurrence before completing it") is REMOVED.
--
-- WHAT THIS SCRIPT DOES
--   1. evidence_link.instance_evidence_id BIGINT NULL (FK
--      practice_instance_evidence) -- which recurring evidence row a task
--      link answers. NULL = general task evidence, as before.
--   2. practice_task_evidence_response -- one row per (task, evidence):
--      the option chosen and, for External, location + locator.
--   3. fn_pm_task_recurring_evidence(@task_id) -- the recurring evidence
--      rows of a scheduled task (the join 473's gate used, now in one
--      place).
--   4. New: sp_task_recurring_evidence_list, sp_task_evidence_response_save.
--   5. Re-issued from 477 (only the marked parts change):
--        sp_task_attachment_add     + @instance_evidence_id
--        sp_task_evidence_link_add  + @instance_evidence_id
--        sp_task_get                result 3 + InstanceEvidenceId
--        sp_task_completion_eligibility  recurring-evidence gate removed
--                                        (result set unchanged)
--
-- Error numbers 52921-52926.
-- DEPENDS ON: 449 (schedule_occurrence_task), 473/475 (cadence view),
--             476/477 (evidence_link Task target, the re-issued bodies),
--             481 (the three option codes).
-- Rollback:   482_task_recurring_evidence_rollback.sql
-- Idempotent. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

DECLARE @ok BIT = 1;
IF OBJECT_ID('grac_practice.schedule_occurrence_task','U') IS NULL
   OR COL_LENGTH('grac_practice.schedule_occurrence_task','practice_instance_obligation_id') IS NULL
BEGIN PRINT 'ABORT (482): schedule_occurrence_task missing -- run 449 first.'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.vw_pm_instance_evidence_cadence','V') IS NULL
BEGIN PRINT 'ABORT (482): vw_pm_instance_evidence_cadence missing -- run 473/475 first.'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.fn_pm_task_evidence_period') IS NULL
   OR COL_LENGTH('grac_practice.evidence_link','legacy_task_attachment_id') IS NULL
BEGIN PRINT 'ABORT (482): the 477 task evidence objects are missing -- run 477 first.'; SET @ok = 0; END
IF COL_LENGTH('grac_practice.practice_instance_evidence','evidence_source') IS NULL
BEGIN PRINT 'ABORT (482): practice_instance_evidence.evidence_source missing -- run 481 first.'; SET @ok = 0; END
IF COL_LENGTH('grac_practice.practice_instance_obligation','obligation_name') IS NULL
BEGIN PRINT 'ABORT (482): practice_instance_obligation.obligation_name missing -- run 140 first.'; SET @ok = 0; END
IF OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_task_completion_eligibility')) NOT LIKE '%evidence_link%'
BEGIN PRINT 'ABORT (482): sp_task_completion_eligibility is older than 477 -- run 477 first.'; SET @ok = 0; END
IF @ok = 0
BEGIN
    RAISERROR('482_task_recurring_evidence: prerequisites failed -- see the messages above.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. evidence_link.instance_evidence_id
-- =====================================================================
IF COL_LENGTH('grac_practice.evidence_link','instance_evidence_id') IS NULL
BEGIN
    ALTER TABLE grac_practice.evidence_link ADD instance_evidence_id BIGINT NULL
        CONSTRAINT fk_pm_evidence_link_instance_evidence
            REFERENCES grac_practice.practice_instance_evidence(evidence_id);
    PRINT '482: evidence_link.instance_evidence_id added.';
END
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes
                WHERE name = 'ix_pm_evidence_link_instance_evidence'
                  AND object_id = OBJECT_ID('grac_practice.evidence_link'))
    CREATE INDEX ix_pm_evidence_link_instance_evidence
        ON grac_practice.evidence_link(target_type, target_id, instance_evidence_id)
        WHERE instance_evidence_id IS NOT NULL;
GO

-- =====================================================================
-- 2. practice_task_evidence_response
-- =====================================================================
IF OBJECT_ID('grac_practice.practice_task_evidence_response','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.practice_task_evidence_response(
        task_evidence_response_id BIGINT IDENTITY(1,1) NOT NULL
            CONSTRAINT pk_pm_task_evidence_response PRIMARY KEY,
        organization_id    BIGINT NOT NULL
            CONSTRAINT fk_pm_task_evidence_response_org
                REFERENCES grac_practice.organization(organization_id),
        task_id            BIGINT NOT NULL
            CONSTRAINT fk_pm_task_evidence_response_task
                REFERENCES grac_practice.practice_task(task_id),
        evidence_id        BIGINT NOT NULL
            CONSTRAINT fk_pm_task_evidence_response_evidence
                REFERENCES grac_practice.practice_instance_evidence(evidence_id),
        evidence_source    NVARCHAR(30)  NOT NULL
            CONSTRAINT ck_pm_task_evidence_response_source
                CHECK (evidence_source IN (N'DirectUpload', N'EvidenceCenter', N'External')),
        evidence_location  NVARCHAR(500) NULL,
        evidence_locator   NVARCHAR(500) NULL,
        entered_by_employee_id BIGINT NULL,
        entered_by         NVARCHAR(100) NOT NULL,
        entered_dt         DATETIME2     NOT NULL
            CONSTRAINT df_pm_task_evidence_response_dt DEFAULT SYSUTCDATETIME(),
        updated_by         NVARCHAR(100) NULL,
        updated_dt         DATETIME2     NULL,
        CONSTRAINT uq_pm_task_evidence_response UNIQUE (task_id, evidence_id)
    );
    PRINT '482: practice_task_evidence_response created.';
END
GO

-- =====================================================================
-- 3. fn_pm_task_recurring_evidence -- the recurring evidence rows of a
--    scheduled task: its occurrence -> instance obligation -> evidence
--    rows of that obligation (published or organisation-defined) whose
--    cadence is Recurring. Same join as 473's gate.
-- =====================================================================
CREATE OR ALTER FUNCTION grac_practice.fn_pm_task_recurring_evidence (@task_id BIGINT)
RETURNS TABLE
AS
RETURN
    SELECT pie.evidence_id,
           pie.practice_instance_id,
           t.organization_id,
           pio.practice_instance_obligation_id,
           pio.obligation_name
    FROM   grac_practice.practice_task t
    JOIN   grac_practice.schedule_occurrence_task x
           ON x.occurrence_task_id = t.source_record_id
    JOIN   grac_practice.practice_instance_obligation pio
           ON pio.practice_instance_obligation_id = x.practice_instance_obligation_id
    JOIN   grac_practice.practice_instance_evidence pie
           ON pie.practice_instance_id = x.practice_instance_id
          AND pie.status = N'Active'
          AND (   (pio.obligation_id IS NOT NULL AND pie.source_obligation_id = pio.obligation_id)
               OR pie.source_practice_instance_obligation_id = pio.practice_instance_obligation_id)
    JOIN   grac_practice.vw_pm_instance_evidence_cadence c
           ON c.evidence_id = pie.evidence_id
    WHERE  t.task_id = @task_id
      AND  t.source_type_code = N'Schedule'
      AND  c.EvidenceCadence = N'Recurring';
GO

-- =====================================================================
-- 4a. sp_task_recurring_evidence_list -- the Complete Task dialog's list.
--     One row per recurring evidence of the task's obligation, with the
--     option chosen so far. The files themselves come with the task
--     (sp_task_get result 3, InstanceEvidenceId).
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_task_recurring_evidence_list
    @task_id         BIGINT,
    @organization_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    IF @task_id IS NULL OR @organization_id IS NULL
        THROW 52921, 'Organization and task are both required.', 1;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.practice_task t
                    WHERE t.task_id = @task_id AND t.organization_id = @organization_id)
        THROW 52922, 'That task was not found in this organization.', 1;

    SELECT r.evidence_id                AS EvidenceId,
           COALESCE(NULLIF(LTRIM(RTRIM(pie.evidence_name)), N''), et.evidence_type_name, N'Evidence') AS EvidenceName,
           pie.evidence_type_id         AS EvidenceTypeId,
           et.evidence_type_name        AS EvidenceType,
           pie.evidence_description     AS EvidenceDescription,
           r.obligation_name            AS ObligationName,
           resp.evidence_source         AS EvidenceSource,
           resp.evidence_location       AS EvidenceLocation,
           resp.evidence_locator        AS EvidenceLocator,
           lk.FileCount                 AS FileCount,
           -- Provided for this occurrence, under the 481 rule: External =
           -- location and locator; the other two = a file linked to it.
           CAST(CASE WHEN resp.evidence_source = N'External'
                      AND NULLIF(LTRIM(RTRIM(ISNULL(resp.evidence_location, N''))), N'') IS NOT NULL
                      AND NULLIF(LTRIM(RTRIM(ISNULL(resp.evidence_locator,  N''))), N'') IS NOT NULL THEN 1
                     WHEN ISNULL(resp.evidence_source, N'') <> N'External' AND lk.FileCount > 0 THEN 1
                     ELSE 0 END AS BIT) AS IsProvided
    FROM   grac_practice.fn_pm_task_recurring_evidence(@task_id) r
    JOIN   grac_practice.practice_instance_evidence pie ON pie.evidence_id = r.evidence_id
    LEFT   JOIN grac_practice.evidence_type_master et ON et.evidence_type_id = pie.evidence_type_id
    LEFT   JOIN grac_practice.practice_task_evidence_response resp
           ON resp.task_id = @task_id AND resp.evidence_id = r.evidence_id
    OUTER  APPLY (SELECT COUNT(*) AS FileCount
                  FROM   grac_practice.evidence_link l
                  WHERE  l.target_type = N'Task' AND l.target_id = @task_id
                    AND  l.instance_evidence_id = r.evidence_id AND l.status = N'Active') lk
    WHERE  r.organization_id = @organization_id
    ORDER  BY r.obligation_name,
              COALESCE(NULLIF(LTRIM(RTRIM(pie.evidence_name)), N''), et.evidence_type_name);
END
GO

-- =====================================================================
-- 4b. sp_task_evidence_response_save -- the option chosen per recurring
--     evidence, and the external reference. Called by Complete Task
--     before the task is completed. Nothing here is required.
--     @payload_json = [{ "evidenceId": 1, "evidenceSource": "External",
--                        "evidenceLocation": "...", "evidenceLocator": "..." }]
--     Location / locator are written only for External; switching to
--     another option keeps what was there.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_task_evidence_response_save
    @task_id             BIGINT,
    @organization_id     BIGINT,
    @payload_json        NVARCHAR(MAX),
    @caller_employee_id  BIGINT        = NULL,
    @caller_display_name NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @task_id IS NULL OR @organization_id IS NULL
        THROW 52921, 'Organization and task are both required.', 1;

    DECLARE @closed_at DATETIME2, @found BIT = 0;
    SELECT @found = 1, @closed_at = t.closed_at
    FROM   grac_practice.practice_task t
    WHERE  t.task_id = @task_id AND t.organization_id = @organization_id;
    IF @found = 0
        THROW 52922, 'That task was not found in this organization.', 1;
    IF @closed_at IS NOT NULL
        THROW 52923, 'This task is already completed. Its evidence can no longer be changed.', 1;
    IF ISJSON(ISNULL(@payload_json, N'')) = 0
        THROW 52926, 'The evidence details could not be read.', 1;

    IF @caller_employee_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee oe
                        WHERE oe.employee_id = @caller_employee_id
                          AND oe.organization_id = @organization_id)
        SET @caller_employee_id = NULL;
    SET @caller_display_name = ISNULL(NULLIF(LTRIM(RTRIM(@caller_display_name)), N''), N'system');

    DECLARE @items TABLE (evidence_id BIGINT NOT NULL PRIMARY KEY, evidence_source NVARCHAR(30) NULL,
                          evidence_location NVARCHAR(500) NULL, evidence_locator NVARCHAR(500) NULL);
    INSERT @items (evidence_id, evidence_source, evidence_location, evidence_locator)
    SELECT j.evidenceId,
           MAX(NULLIF(LTRIM(RTRIM(j.evidenceSource)), N'')),
           MAX(NULLIF(LTRIM(RTRIM(j.evidenceLocation)), N'')),
           MAX(NULLIF(LTRIM(RTRIM(j.evidenceLocator)), N''))
    FROM   OPENJSON(@payload_json)
           WITH (evidenceId       BIGINT        '$.evidenceId',
                 evidenceSource   NVARCHAR(30)  '$.evidenceSource',
                 evidenceLocation NVARCHAR(500) '$.evidenceLocation',
                 evidenceLocator  NVARCHAR(500) '$.evidenceLocator') j
    WHERE  j.evidenceId IS NOT NULL
    GROUP  BY j.evidenceId;

    -- No option chosen = nothing to record for that row.
    DELETE @items WHERE evidence_source IS NULL;

    IF EXISTS (SELECT 1 FROM @items
                WHERE evidence_source NOT IN (N'DirectUpload', N'EvidenceCenter', N'External'))
        THROW 52924, 'Choose how the evidence is provided: Direct Upload, Evidence Center Reference or External Evidence Reference.', 1;
    IF EXISTS (SELECT 1 FROM @items i
                WHERE NOT EXISTS (SELECT 1 FROM grac_practice.fn_pm_task_recurring_evidence(@task_id) r
                                   WHERE r.evidence_id = i.evidence_id))
        THROW 52925, 'That evidence is not asked for on this task.', 1;

    DECLARE @saved TABLE (task_evidence_response_id BIGINT, evidence_id BIGINT, action_type NVARCHAR(10));

    BEGIN TRAN;

    MERGE grac_practice.practice_task_evidence_response AS target
    USING @items AS src
       ON target.task_id = @task_id AND target.evidence_id = src.evidence_id
    WHEN MATCHED THEN UPDATE SET
         evidence_source   = src.evidence_source,
         evidence_location = CASE WHEN src.evidence_source = N'External' THEN src.evidence_location ELSE target.evidence_location END,
         evidence_locator  = CASE WHEN src.evidence_source = N'External' THEN src.evidence_locator  ELSE target.evidence_locator  END,
         updated_by        = @caller_display_name,
         updated_dt        = SYSUTCDATETIME()
    WHEN NOT MATCHED THEN INSERT
         (organization_id, task_id, evidence_id, evidence_source, evidence_location, evidence_locator,
          entered_by_employee_id, entered_by)
    VALUES
         (@organization_id, @task_id, src.evidence_id, src.evidence_source,
          CASE WHEN src.evidence_source = N'External' THEN src.evidence_location END,
          CASE WHEN src.evidence_source = N'External' THEN src.evidence_locator END,
          @caller_employee_id, @caller_display_name)
    OUTPUT inserted.task_evidence_response_id, inserted.evidence_id,
           CASE WHEN $action = N'INSERT' THEN N'CREATE' ELSE N'UPDATE' END
      INTO @saved (task_evidence_response_id, evidence_id, action_type);

    INSERT grac_practice.practice_audit_trace(entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    SELECT N'task-evidence-response', s.task_evidence_response_id, s.action_type, NULL,
           (SELECT @task_id AS taskId, r.evidence_id AS evidenceId, r.evidence_source AS evidenceSource,
                   r.evidence_location AS evidenceLocation, r.evidence_locator AS evidenceLocator
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
           N'Active', @caller_display_name
    FROM   @saved s
    JOIN   grac_practice.practice_task_evidence_response r
           ON r.task_evidence_response_id = s.task_evidence_response_id;

    COMMIT;

    SELECT (SELECT COUNT(*) FROM @saved) AS SavedCount,
           N'Evidence details saved.' AS Message;
END
GO

-- =====================================================================
-- 5a. sp_task_attachment_add (477 body; + @instance_evidence_id)
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_task_attachment_add
    @task_id                 BIGINT,
    @file_name               NVARCHAR(500),
    @content_type            NVARCHAR(200)  = NULL,
    @file_data               VARBINARY(MAX),
    @evidence_description    NVARCHAR(1000) = NULL,
    @uploaded_by_employee_id BIGINT         = NULL,
    @caller_display_name     NVARCHAR(100)  = N'system',
    @caller_is_admin         BIT            = 0,      -- 477
    @instance_evidence_id    BIGINT         = NULL    -- 482: NULL = general task evidence
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

    -- 482: the recurring evidence row of this task the file answers.
    IF @instance_evidence_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM grac_practice.fn_pm_task_recurring_evidence(@task_id) r
                        WHERE r.evidence_id = @instance_evidence_id)
        THROW 52925, 'That evidence is not asked for on this task.', 1;

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
            -- 482: the file already on the task now also answers this
            -- recurring evidence, when it answered none before.
            IF @instance_evidence_id IS NOT NULL
                UPDATE grac_practice.evidence_link
                   SET instance_evidence_id = @instance_evidence_id
                 WHERE evidence_link_id = @link_id AND instance_evidence_id IS NULL;
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
         linked_by_employee_id, linked_by, linked_dt, instance_evidence_id)   -- 482
    VALUES
        (@organization_id, @item_id, @file_id, N'Task', @task_id,
         @instance_id, NULLIF(LTRIM(RTRIM(@evidence_description)), N''), @period, @period, N'Active',
         @uploaded_by_employee_id, @caller_display_name, SYSUTCDATETIME(), @instance_evidence_id);
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


-- =====================================================================
-- 5b. sp_task_evidence_link_add (477 body; + @instance_evidence_id)
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_task_evidence_link_add
    @task_id             BIGINT,
    @organization_id     BIGINT,
    @evidence_item_id    BIGINT,
    @link_note           NVARCHAR(1000) = NULL,
    @caller_employee_id  BIGINT         = NULL,
    @caller_is_admin     BIT            = 0,
    @caller_display_name NVARCHAR(100)  = N'system',
    @instance_evidence_id BIGINT        = NULL      -- 482: NULL = general task evidence
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
    -- 482: the recurring evidence row of this task the file answers.
    IF @instance_evidence_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM grac_practice.fn_pm_task_recurring_evidence(@task_id) r
                        WHERE r.evidence_id = @instance_evidence_id)
        THROW 52925, 'That evidence is not asked for on this task.', 1;

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
         linked_by_employee_id, linked_by, linked_dt, instance_evidence_id)   -- 482
    VALUES
        (@organization_id, @evidence_item_id, @file_id, N'Task', @task_id,
         @instance_id, NULLIF(LTRIM(RTRIM(@link_note)), N''), @period, @period, N'Active',
         @caller_employee_id, @caller_display_name, SYSUTCDATETIME(), @instance_evidence_id);
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


-- =====================================================================
-- 5c. sp_task_get (477 body; result 3 + InstanceEvidenceId)
-- =====================================================================
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
           f.uploaded_dt           AS FileUploadedDt,
           l.instance_evidence_id  AS InstanceEvidenceId   -- 482
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


-- =====================================================================
-- 5d. sp_task_completion_eligibility (477 body; recurring-evidence gate removed)
-- =====================================================================
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

    -- 482: the 473 recurring-evidence gate is removed (change request
    -- 2026-10-23: evidence on Complete Task is not mandatory). The
    -- recurring evidence rows are listed on the dialog instead
    -- (sp_task_recurring_evidence_list). @source_type / @source_record_id
    -- are still read above, unused, so the body stays the 477 one.

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
-- 6. Verification
-- =====================================================================
SELECT '482 evidence_link.instance_evidence_id' AS Check_,
       CASE WHEN COL_LENGTH('grac_practice.evidence_link','instance_evidence_id') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END AS Result_
UNION ALL
SELECT '482 practice_task_evidence_response',
       CASE WHEN OBJECT_ID('grac_practice.practice_task_evidence_response','U') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '482 new objects',
       CASE WHEN OBJECT_ID('grac_practice.fn_pm_task_recurring_evidence') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_task_recurring_evidence_list','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_task_evidence_response_save','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '482 upload / link take @instance_evidence_id',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_task_attachment_add'))    LIKE '%@instance_evidence_id%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_task_evidence_link_add')) LIKE '%@instance_evidence_id%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '482 sp_task_get returns InstanceEvidenceId',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_task_get')) LIKE '%InstanceEvidenceId%' THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '482 completion no longer gated on recurring evidence',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_task_completion_eligibility')) NOT LIKE '%@recurring_count%'
            THEN 'PASS' ELSE 'FAIL' END;

-- Open scheduled tasks per organisation that now list recurring evidence.
SELECT t.organization_id AS OrganizationId,
       COUNT(DISTINCT t.task_id) AS OpenScheduledTasks,
       COUNT(r.evidence_id)      AS RecurringEvidenceRows
FROM   grac_practice.practice_task t
CROSS  APPLY grac_practice.fn_pm_task_recurring_evidence(t.task_id) r
WHERE  t.closed_at IS NULL
GROUP  BY t.organization_id
ORDER  BY t.organization_id;

PRINT '482 task recurring evidence complete. Deploy API + Web next.';
GO

SET NOEXEC OFF;
GO
