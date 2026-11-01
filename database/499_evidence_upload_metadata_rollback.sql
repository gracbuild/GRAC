-- =====================================================================
-- 499 ROLLBACK -- restore the 476 / 482 bodies verbatim
--
-- Drops the eight metadata parameters from both upload procedures. A
-- Direct Upload then goes back to storing the file in the Evidence
-- Center with no title, description, validity, tags or chosen owner --
-- the state 499 was written to fix.
--
-- Run the Api change back out too, or the upload will post form fields
-- the procedures no longer declare. (The Api binds them through
-- ProcParameterProbe, so in practice it simply stops sending them; this
-- note is here because that guard is the only thing preventing a "has
-- too many arguments specified" failure.)
--
-- Items already created WITH metadata keep it -- this only changes what
-- future uploads capture.
--
-- SAFE TO RE-RUN (CREATE OR ALTER). ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID('grac_practice.sp_evidence_item_store','P') IS NULL
   OR OBJECT_ID('grac_practice.evidence_link','U') IS NULL
BEGIN
    PRINT 'ABORT (499 rollback): run 476 / 482 first.';
    SET NOEXEC ON;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_resolve_evidence_attachment_add
    @practice_instance_id    BIGINT,
    @evidence_id             BIGINT,
    @file_name               NVARCHAR(500),
    @content_type            NVARCHAR(200)  = NULL,
    @file_data               VARBINARY(MAX),
    @attachment_description  NVARCHAR(1000) = NULL,
    @uploaded_by_employee_id BIGINT         = NULL,
    @actor                   NVARCHAR(100)  = N'system',
    -- The organisation the Web tier checked the caller against. NULL = no
    -- check (a call from SQL); when given, the instance must belong to it.
    @organization_id         BIGINT         = NULL,
    -- 476: whether the uploader is an organisation admin (session data
    -- scope), for the "identical file you can already see" lookup.
    @caller_is_admin         BIT            = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @practice_instance_id IS NULL OR @evidence_id IS NULL
        THROW 52760, 'sp_resolve_evidence_attachment_add: practice instance and evidence row are both required.', 1;
    IF @file_name IS NULL OR LEN(LTRIM(RTRIM(@file_name))) = 0
        THROW 52761, 'sp_resolve_evidence_attachment_add: a file name is required.', 1;
    IF @file_data IS NULL OR DATALENGTH(@file_data) = 0
        THROW 52762, 'sp_resolve_evidence_attachment_add: the file is empty.', 1;

    DECLARE @row_organization_id BIGINT, @cadence NVARCHAR(30), @type_id INT;
    SELECT @row_organization_id = e.organization_id,
           @cadence             = c.EvidenceCadence,
           @type_id             = e.evidence_type_id
    FROM   grac_practice.practice_instance_evidence e
    LEFT   JOIN grac_practice.vw_pm_instance_evidence_cadence c ON c.evidence_id = e.evidence_id
    WHERE  e.evidence_id          = @evidence_id
      AND  e.practice_instance_id = @practice_instance_id
      AND  e.status = N'Active'
      AND  (@organization_id IS NULL OR e.organization_id = @organization_id);
    SET @organization_id = @row_organization_id;

    IF @organization_id IS NULL
        THROW 52763, 'sp_resolve_evidence_attachment_add: that evidence row was not found on this practice instance.', 1;
    IF ISNULL(@cadence, N'Recurring') <> N'OneTime'
        THROW 52764, 'Only one-time evidence is attached on Operationalize. Recurring evidence is attached to each scheduled task when it is completed.', 1;

    IF @uploaded_by_employee_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee oe
                        WHERE oe.employee_id = @uploaded_by_employee_id
                          AND oe.organization_id = @organization_id)
        SET @uploaded_by_employee_id = NULL;

    IF @type_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM grac_practice.evidence_type_master t WHERE t.evidence_type_id = @type_id)
        SET @type_id = NULL;

    SET @actor = ISNULL(NULLIF(LTRIM(RTRIM(@actor)), N''), N'system');

    DECLARE @hash VARBINARY(32) = HASHBYTES('SHA2_256', @file_data);
    DECLARE @size BIGINT = DATALENGTH(@file_data);
    DECLARE @today DATE = CONVERT(DATE, SYSUTCDATETIME());
    DECLARE @item_id BIGINT, @file_id BIGINT, @version_no INT, @title NVARCHAR(300), @link_id BIGINT;

    -- The identical file, already in the Evidence Center and visible to
    -- the uploader.
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
      AND  (i.valid_to IS NULL OR i.valid_to >= @today)
    ORDER  BY i.evidence_item_id;

    IF @item_id IS NOT NULL
    BEGIN
        SELECT @link_id = l.evidence_link_id
        FROM   grac_practice.evidence_link l
        WHERE  l.target_type = N'InstanceEvidence' AND l.target_id = @evidence_id
          AND  l.evidence_item_id = @item_id AND l.status = N'Active';

        IF @link_id IS NOT NULL
        BEGIN
            SELECT @link_id AS EvidenceAttachmentId, @size AS FileSizeBytes, @item_id AS EvidenceItemId,
                   CAST(1 AS BIT) AS Reused,
                   N'This file is already attached to this evidence.' AS Message;
            RETURN;
        END

        BEGIN TRAN;
        INSERT grac_practice.evidence_link
            (organization_id, evidence_item_id, evidence_file_id, target_type, target_id,
             practice_instance_id, link_note, status, linked_by_employee_id, linked_by, linked_dt)
        VALUES
            (@organization_id, @item_id, @file_id, N'InstanceEvidence', @evidence_id,
             @practice_instance_id, NULLIF(LTRIM(RTRIM(@attachment_description)), N''), N'Active',
             @uploaded_by_employee_id, @actor, SYSUTCDATETIME());
        SET @link_id = SCOPE_IDENTITY();

        INSERT grac_practice.practice_audit_trace(entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
        SELECT N'evidence-link', @link_id, N'CREATE', NULL,
               (SELECT @item_id AS evidenceItemId, @version_no AS versionNo,
                       @practice_instance_id AS practiceInstanceId, @evidence_id AS evidenceId,
                       CAST(1 AS BIT) AS reusedIdenticalFile
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
               N'Active', @actor;
        COMMIT;

        SELECT @link_id AS EvidenceAttachmentId, @size AS FileSizeBytes, @item_id AS EvidenceItemId,
               CAST(1 AS BIT) AS Reused,
               N'This file is already in the Evidence Center as "' + @title + N'" (version '
                 + CAST(@version_no AS NVARCHAR(10)) + N'). It was linked instead of stored again.' AS Message;
        RETURN;
    END

    BEGIN TRAN;

    SET @item_id = NULL;
    EXEC grac_practice.sp_evidence_item_store
         @organization_id = @organization_id, @evidence_item_id = @item_id OUTPUT,
         @file_name = @file_name, @content_type = @content_type, @file_data = @file_data,
         @file_sha256 = @hash, @evidence_type_id = @type_id,
         @owner_employee_id = @uploaded_by_employee_id, @classification = N'Internal',
         @caller_employee_id = @uploaded_by_employee_id, @actor = @actor,
         @evidence_file_id = @file_id OUTPUT, @version_no = @version_no OUTPUT;

    INSERT grac_practice.evidence_link
        (organization_id, evidence_item_id, evidence_file_id, target_type, target_id,
         practice_instance_id, link_note, status, linked_by_employee_id, linked_by, linked_dt)
    VALUES
        (@organization_id, @item_id, @file_id, N'InstanceEvidence', @evidence_id,
         @practice_instance_id, NULLIF(LTRIM(RTRIM(@attachment_description)), N''), N'Active',
         @uploaded_by_employee_id, @actor, SYSUTCDATETIME());
    SET @link_id = SCOPE_IDENTITY();

    INSERT grac_practice.practice_audit_trace(entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    SELECT N'evidence-link', @link_id, N'CREATE', NULL,
           (SELECT @item_id AS evidenceItemId, @version_no AS versionNo,
                   @practice_instance_id AS practiceInstanceId, @evidence_id AS evidenceId,
                   LTRIM(RTRIM(@file_name)) AS fileName, @size AS fileSizeBytes
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
           N'Active', @actor;

    COMMIT;

    SELECT @link_id AS EvidenceAttachmentId, @size AS FileSizeBytes, @item_id AS EvidenceItemId,
           CAST(0 AS BIT) AS Reused,
           N'Evidence attached. It is also in the Evidence Center for reuse.' AS Message;
END
GO

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

PRINT '=== 499 rollback verification ===';
SELECT '499 rollback: metadata parameters gone from both procedures' AS Check_,
       CASE WHEN (SELECT COUNT(*) FROM sys.parameters
                  WHERE object_id IN (OBJECT_ID('grac_practice.sp_resolve_evidence_attachment_add','P'),
                                      OBJECT_ID('grac_practice.sp_task_attachment_add','P'))
                    AND name IN ('@evidence_title','@valid_from','@valid_to','@tags')) = 0
            THEN 'PASS' ELSE 'FAIL' END AS Result;
GO

SET NOEXEC OFF;
GO
