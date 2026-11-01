-- =====================================================================
-- 499_evidence_upload_metadata.sql
--
-- THE FAULT
-- ---------
-- Operationalize (one-time evidence) and Complete Task (recurring
-- evidence) both offer Direct Upload, and Direct Upload was a bare file
-- picker. The file IS stored in the Evidence Center -- both procedures
-- call sp_evidence_item_store -- but it lands there with no title, no
-- description, no validity window, no tags, no chosen owner and, on the
-- task side, no evidence type either. The operator then has to go to the
-- Evidence Center and fill it all in again on an item they just created.
--
-- WHY
-- ---
-- sp_evidence_item_store (476) already accepts every one of those fields:
--   @evidence_title, @evidence_type_id, @evidence_description,
--   @owner_employee_id, @valid_from, @valid_to, @classification, @tags
-- The two callers simply never passed them:
--   * sp_resolve_evidence_attachment_add (476 body) passed the evidence
--     ROW's type, the uploader as owner, and hard-coded 'Internal'.
--   * sp_task_attachment_add (482 body) passed even less -- no type at
--     all, no title.
-- Nothing was missing from the store; the metadata was never collected
-- and never handed over.
--
-- WHAT THIS DOES
-- --------------
-- Re-issues both procedures with the same eight optional parameters and
-- passes them through to sp_evidence_item_store. sp_evidence_item_store
-- itself is NOT touched.
--
-- Every parameter is optional and defaulted, so this is backward
-- compatible in both directions:
--   * an older Api that does not send them behaves exactly as before
--     (NULL -> the pre-499 default), and
--   * the Api binds them only when the procedure declares them
--     (ProcParameterProbe), so the new Api works against a database
--     where 499 has not been run yet.
--
-- Deliberately NOT applied on the "identical file is already in the
-- Evidence Center" branch of either procedure. That branch links an item
-- somebody else created and described; writing this upload's metadata
-- over theirs would be editing their record rather than describing this
-- upload. The link is made, their description stands.
--
-- Normalisation, identical in both procedures so one upload behaves the
-- same from either screen:
--   * a type that is not in evidence_type_master -> NULL
--   * an owner who is not an employee of this organisation -> the
--     uploader (what the item got before 499)
--   * blank classification -> 'Internal' (the old hard-coded value)
--   * blank title / description / tags -> NULL, never ''
-- On the resolve side the dialog's type WINS over the evidence row's own
-- type; leaving it blank keeps the pre-499 inheritance.
--
-- No schema change. No data migration -- items already created without
-- metadata keep what they have and can be edited in the Evidence Center.
--
-- Re-issued from: 476 (sp_resolve_evidence_attachment_add),
--                 482 (sp_task_attachment_add).
-- SAFE TO RE-RUN (CREATE OR ALTER). Requires 476 and 482.
-- Rollback: database/499_evidence_upload_metadata_rollback.sql
-- ASCII-only on purpose: sqlcmd reads files in the current ANSI codepage
-- by default and multi-byte characters can corrupt string literals.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;   -- defensive: reset in case a prior script left it on
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

-- Guard on the OBJECTS and COLUMNS these bodies read, not merely on the
-- procedures existing: both are re-issued from an earlier migration.
IF OBJECT_ID('grac_practice.sp_evidence_item_store','P') IS NULL
   OR OBJECT_ID('grac_practice.sp_resolve_evidence_attachment_add','P') IS NULL
   OR OBJECT_ID('grac_practice.sp_task_attachment_add','P') IS NULL
   OR OBJECT_ID('grac_practice.evidence_item','U') IS NULL
   OR OBJECT_ID('grac_practice.evidence_link','U') IS NULL
   OR OBJECT_ID('grac_practice.evidence_type_master','U') IS NULL
   OR OBJECT_ID('grac_practice.organization_employee','U') IS NULL
BEGIN
    PRINT 'ABORT (499): run 476 and 482 first.';
    SET NOEXEC ON;
END
GO

-- sp_evidence_item_store must already take the metadata this script
-- forwards; without these parameters the EXECs below would fail at run
-- time with "has too many arguments specified".
IF NOT EXISTS (SELECT 1 FROM sys.parameters
               WHERE object_id = OBJECT_ID('grac_practice.sp_evidence_item_store','P')
                 AND name IN ('@evidence_title','@evidence_description','@valid_from','@valid_to','@tags','@classification','@evidence_type_id','@owner_employee_id')
               GROUP BY object_id HAVING COUNT(*) = 8)
BEGIN
    PRINT 'ABORT (499): sp_evidence_item_store does not take the metadata parameters -- run 476 first.';
    SET NOEXEC ON;
END
GO

IF COL_LENGTH('grac_practice.evidence_link','instance_evidence_id') IS NULL
BEGIN
    PRINT 'ABORT (499): evidence_link.instance_evidence_id missing -- run 482 first.';
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. sp_resolve_evidence_attachment_add  (476 body + the metadata)
--    Operationalize -> one-time evidence -> Direct Upload
-- =====================================================================
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
    @caller_is_admin         BIT            = 0,
    -- =================================================================
    -- 499: the Evidence Center metadata the shared upload dialog now
    -- captures. Every one is optional and defaulted, so the older
    -- callers (and any SQL caller) behave exactly as before: NULL means
    -- "no opinion" and the pre-499 default is used.
    --
    -- They are not read on the "identical file already in the Evidence
    -- Center" branch below -- that branch links an item somebody else
    -- already described, and overwriting their metadata from this screen
    -- would be editing their record, not describing this upload.
    -- =================================================================
    @evidence_title          NVARCHAR(300)  = NULL,
    @evidence_type_id        INT            = NULL,
    @evidence_description    NVARCHAR(2000) = NULL,
    @owner_employee_id       BIGINT         = NULL,
    @valid_from              DATE           = NULL,
    @valid_to                DATE           = NULL,
    @classification          NVARCHAR(30)   = NULL,
    @tags                    NVARCHAR(500)  = NULL
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

    -- 499: the dialog's Evidence type wins over the row's own default.
    -- NULL (dialog not used, or left blank) keeps the pre-499 behaviour of
    -- inheriting the evidence row's type.
    IF @evidence_type_id IS NOT NULL SET @type_id = @evidence_type_id;

    IF @type_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM grac_practice.evidence_type_master t WHERE t.evidence_type_id = @type_id)
        SET @type_id = NULL;

    -- 499: an owner picked in the dialog, validated the same way the
    -- uploader is. Anything not an employee of this organisation falls
    -- back to the uploader, which is what the item got before 499.
    IF @owner_employee_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee oe
                        WHERE oe.employee_id = @owner_employee_id
                          AND oe.organization_id = @organization_id)
        SET @owner_employee_id = NULL;
    SET @owner_employee_id = COALESCE(@owner_employee_id, @uploaded_by_employee_id);

    -- 499: blank is not a classification. NULL or '' keeps 'Internal',
    -- the value this procedure hard-coded before.
    SET @classification = ISNULL(NULLIF(LTRIM(RTRIM(@classification)), N''), N'Internal');
    SET @evidence_title       = NULLIF(LTRIM(RTRIM(@evidence_title)), N'');
    SET @evidence_description = NULLIF(LTRIM(RTRIM(@evidence_description)), N'');
    SET @tags                 = NULLIF(LTRIM(RTRIM(@tags)), N'');

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
    -- 499: every field the dialog captured goes in. sp_evidence_item_store
    -- has accepted all of them since 476 -- they were simply never passed,
    -- which is why a file uploaded from Operationalize arrived in the
    -- Evidence Center with no title, validity, classification or tags.
    EXEC grac_practice.sp_evidence_item_store
         @organization_id = @organization_id, @evidence_item_id = @item_id OUTPUT,
         @file_name = @file_name, @content_type = @content_type, @file_data = @file_data,
         @file_sha256 = @hash, @evidence_type_id = @type_id,
         @evidence_title = @evidence_title,
         @evidence_description = @evidence_description,
         @owner_employee_id = @owner_employee_id,
         @valid_from = @valid_from, @valid_to = @valid_to,
         @classification = @classification, @tags = @tags,
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

-- =====================================================================
-- 2. sp_task_attachment_add  (482 body + the metadata)
--    Complete Task -> evidence -> Direct Upload
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
    @instance_evidence_id    BIGINT         = NULL,   -- 482: NULL = general task evidence
    -- =================================================================
    -- 499: the Evidence Center metadata the shared upload dialog now
    -- captures, the same set sp_resolve_evidence_attachment_add gained.
    -- All optional and defaulted, so every existing caller is unchanged.
    -- Not read on the "identical file already there" branch: that links
    -- an item somebody else described.
    -- =================================================================
    @evidence_title          NVARCHAR(300)  = NULL,
    @evidence_type_id        INT            = NULL,
    @evidence_detail         NVARCHAR(2000) = NULL,
    @owner_employee_id       BIGINT         = NULL,
    @valid_from              DATE           = NULL,
    @valid_to                DATE           = NULL,
    @classification          NVARCHAR(30)   = NULL,
    @tags                    NVARCHAR(500)  = NULL
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

    -- 499: the dialog's fields, normalised the same way the resolve-side
    -- procedure normalises them, so one upload behaves identically from
    -- either screen.
    IF @evidence_type_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM grac_practice.evidence_type_master et
                        WHERE et.evidence_type_id = @evidence_type_id)
        SET @evidence_type_id = NULL;

    IF @owner_employee_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee oe
                        WHERE oe.employee_id = @owner_employee_id
                          AND oe.organization_id = @organization_id)
        SET @owner_employee_id = NULL;
    SET @owner_employee_id = COALESCE(@owner_employee_id, @uploaded_by_employee_id);

    SET @classification   = ISNULL(NULLIF(LTRIM(RTRIM(@classification)), N''), N'Internal');
    SET @evidence_title   = NULLIF(LTRIM(RTRIM(@evidence_title)), N'');
    SET @evidence_detail  = NULLIF(LTRIM(RTRIM(@evidence_detail)), N'');
    SET @tags             = NULLIF(LTRIM(RTRIM(@tags)), N'');

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
        -- 499: carry the dialog's metadata. Before this the task upload
        -- passed neither a type nor a title, so a file attached while
        -- completing a task reached the Evidence Center emptier still
        -- than the Operationalize one.
        EXEC grac_practice.sp_evidence_item_store
             @organization_id = @organization_id, @evidence_item_id = @item_id OUTPUT,
             @file_name = @file_name, @content_type = @content_type, @file_data = @file_data,
             @file_sha256 = @hash,
             @evidence_type_id = @evidence_type_id,
             @evidence_title = @evidence_title,
             @evidence_description = @evidence_detail,
             @owner_employee_id = @owner_employee_id,
             @valid_from = @valid_from, @valid_to = @valid_to,
             @classification = @classification, @tags = @tags,
             @caller_employee_id = @uploaded_by_employee_id,
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
-- Verification
-- =====================================================================
PRINT '=== 499 verification ===';

SELECT '499 resolve upload takes the 8 metadata parameters' AS Check_,
       CASE WHEN (SELECT COUNT(*) FROM sys.parameters
                  WHERE object_id = OBJECT_ID('grac_practice.sp_resolve_evidence_attachment_add','P')
                    AND name IN ('@evidence_title','@evidence_type_id','@evidence_description',
                                 '@owner_employee_id','@valid_from','@valid_to','@classification','@tags')) = 8
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '499 task upload takes the 8 metadata parameters',
       CASE WHEN (SELECT COUNT(*) FROM sys.parameters
                  WHERE object_id = OBJECT_ID('grac_practice.sp_task_attachment_add','P')
                    AND name IN ('@evidence_title','@evidence_type_id','@evidence_detail',
                                 '@owner_employee_id','@valid_from','@valid_to','@classification','@tags')) = 8
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '499 resolve upload forwards the title to the store',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_resolve_evidence_attachment_add','P'))
                 LIKE '%@evidence_title = @evidence_title%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '499 task upload forwards the title to the store',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_task_attachment_add','P'))
                 LIKE '%@evidence_title = @evidence_title%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '499 classification is no longer hard-coded on either path',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_resolve_evidence_attachment_add','P'))
                 NOT LIKE '%@classification = N''Internal''%'
            AND  OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_task_attachment_add','P'))
                 NOT LIKE '%@classification = N''Internal''%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '499 sp_evidence_item_store itself is unchanged by this script',
       CASE WHEN (SELECT COUNT(*) FROM sys.parameters
                  WHERE object_id = OBJECT_ID('grac_practice.sp_evidence_item_store','P')) = 19
            THEN 'PASS' ELSE 'INFO (parameter count differs -- check 476 was not re-issued)' END;
GO

SET NOEXEC OFF;
GO
