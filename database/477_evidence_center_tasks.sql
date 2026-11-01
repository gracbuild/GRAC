-- =====================================================================
-- 477_evidence_center_tasks.sql
--
-- REQUEST (2026-10-18)
-- --------------------
--   Evidence Center, Phase 2 ("Evidence Center - Architecture Plan",
--   agreed 2026-10-18; Phase 1 = 476):
--     * Task completion (recurring evidence) uses the Evidence Center:
--       a file attached to a task is stored once and linked; an item
--       already in the Evidence Center can be selected instead.
--     * Validity-versus-period rule (agreed): older evidence may be
--       referenced only when its validity covers the occurrence period.
--     * The existing task_attachment files move into the Evidence Center.
--     * Expiry notifications: "evidence expiring in 30 days".
--
-- WHAT THIS FILE DOES
-- -------------------
--   1. evidence_link takes a second target: 'Task' (target_id =
--      practice_task.task_id, practice_instance_id = the task's linked
--      instance, period_from = period_to = the task's period date).
--      New column legacy_task_attachment_id (the task_attachment row a
--      link was migrated from).
--   2. fn_pm_task_evidence_period -- the task's period date: the
--      occurrence date of a scheduled occurrence task (449), otherwise
--      today (UTC).
--      fn_pm_evidence_item_visible re-issued: an item is also visible
--      through a task the caller can see (practice_task is under the View
--      Data Scope policy, 415). Everything else in the rule is unchanged.
--   3. Migration of task_attachment: one item per distinct file
--      (SHA-256) per organisation, reusing a 476 item with the identical
--      current file; one link per attachment. task_attachment is NOT
--      changed or dropped. Re-runnable.
--   4. Procedures
--        sp_task_evidence_candidates   picker list for one task; an item
--                                      whose validity does not cover the
--                                      task's period is listed, not linkable
--        sp_task_evidence_link_add     link an item to a task (pins the
--                                      current version, records the period)
--      re-issued over links, same contracts:
--        sp_task_attachment_add        the file becomes an Evidence Center
--                                      item (or links the identical one the
--                                      uploader can see and whose validity
--                                      covers the period)
--        sp_task_attachment_get        the pinned version
--        sp_task_get                   result 3 (evidence) reads links
--                                      (195 body otherwise unchanged)
--        sp_task_completion_eligibility counts links (473 body otherwise
--                                      unchanged)
--        sp_evidence_center_get        Used in lists tasks too
--   5. Expiry notifications
--        evidence_expiry_notice        one row per item, recipient, notice
--                                      (Expiring / Expired) and valid-to date
--        sp_evidence_expiry_sweep      raises the notices (worker pass in
--                                      the API, or SQL Agent)
--        sp_evidence_expiry_notice_list / _mark   My Notifications
--
--   A task link is never refreshed to a newer version: a task completed
--   for a period keeps the file it was completed with (plan, decision 1).
--   Task evidence has no remove (task_attachment never had one).
--
-- ERROR NUMBERS: 52860-52869 (user-facing sentences); 55608-55612 keep
--   their 193 texts.
--
-- DEPENDS ON: 476 (Evidence Center), 473 (completion gate), 449
--   (schedule_occurrence_task), 195 (sp_task_get), 193 (task attachments).
-- Rollback: 477_evidence_center_tasks_rollback.sql
-- SAFE TO RE-RUN. ASCII-only. SQL Server 2016+.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOEXEC OFF;
GO

DECLARE @prereqs_ok BIT = 1;
IF OBJECT_ID('grac_practice.evidence_link','U') IS NULL
   OR OBJECT_ID('grac_practice.sp_evidence_item_store','P') IS NULL
BEGIN PRINT 'ABORT (477): the Evidence Center is missing. Run 476 first.'; SET @prereqs_ok = 0; END
IF @prereqs_ok = 1 AND OBJECT_ID('grac_practice.task_attachment','U') IS NULL
BEGIN PRINT 'ABORT (477): task_attachment missing (192).'; SET @prereqs_ok = 0; END
IF @prereqs_ok = 1 AND OBJECT_ID('grac_practice.schedule_occurrence_task','U') IS NULL
BEGIN PRINT 'ABORT (477): schedule_occurrence_task missing. Run 449 first.'; SET @prereqs_ok = 0; END
IF @prereqs_ok = 1 AND OBJECT_ID('grac_practice.vw_pm_instance_evidence_cadence','V') IS NULL
BEGIN PRINT 'ABORT (477): vw_pm_instance_evidence_cadence missing. Run 473 / 475 first.'; SET @prereqs_ok = 0; END
IF @prereqs_ok = 0
BEGIN
    RAISERROR('477_evidence_center_tasks: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. evidence_link: the 'Task' target
-- =====================================================================
IF EXISTS (SELECT 1 FROM sys.check_constraints
            WHERE name = 'ck_pm_evidence_link_target'
              AND parent_object_id = OBJECT_ID('grac_practice.evidence_link')
              AND definition NOT LIKE '%Task%')
BEGIN
    ALTER TABLE grac_practice.evidence_link DROP CONSTRAINT ck_pm_evidence_link_target;
    PRINT '477: ck_pm_evidence_link_target dropped (re-created with Task).';
END
GO
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints
                WHERE name = 'ck_pm_evidence_link_target'
                  AND parent_object_id = OBJECT_ID('grac_practice.evidence_link'))
BEGIN
    ALTER TABLE grac_practice.evidence_link WITH CHECK
        ADD CONSTRAINT ck_pm_evidence_link_target CHECK (target_type IN (N'InstanceEvidence', N'Task'));
    PRINT '477: ck_pm_evidence_link_target = InstanceEvidence / Task.';
END
GO

IF COL_LENGTH('grac_practice.evidence_link','legacy_task_attachment_id') IS NULL
BEGIN
    ALTER TABLE grac_practice.evidence_link ADD legacy_task_attachment_id BIGINT NULL
        CONSTRAINT fk_pm_evidence_link_legacy_task
            REFERENCES grac_practice.task_attachment(task_attachment_id);
    PRINT '477: evidence_link.legacy_task_attachment_id added.';
END
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes
                WHERE name = 'ux_pm_evidence_link_legacy_task'
                  AND object_id = OBJECT_ID('grac_practice.evidence_link'))
    CREATE UNIQUE INDEX ux_pm_evidence_link_legacy_task
        ON grac_practice.evidence_link(legacy_task_attachment_id)
        WHERE legacy_task_attachment_id IS NOT NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes
                WHERE name = 'ix_pm_evidence_link_target'
                  AND object_id = OBJECT_ID('grac_practice.evidence_link'))
    CREATE INDEX ix_pm_evidence_link_target
        ON grac_practice.evidence_link(target_type, target_id, status)
        INCLUDE (evidence_item_id, evidence_file_id);
GO

-- =====================================================================
-- 2. Period and visibility
-- =====================================================================
-- The date a task's evidence must be valid on: the occurrence date of a
-- scheduled occurrence task (449), otherwise today (UTC).
CREATE OR ALTER FUNCTION grac_practice.fn_pm_task_evidence_period (@task_id BIGINT)
RETURNS TABLE
AS
RETURN
SELECT COALESCE(
           (SELECT TOP 1 x.occurrence_date
            FROM   grac_practice.practice_task t
            JOIN   grac_practice.schedule_occurrence_task x
                   ON t.source_type_code = N'Schedule'
                  AND x.occurrence_task_id = t.source_record_id
            WHERE  t.task_id = @task_id),
           CONVERT(DATE, SYSUTCDATETIME())) AS period_date;
GO

-- 476 rule + "a task the caller can see" (practice_task under View Data
-- Scope). Same parameters, so every caller is unchanged.
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
                     AND  l.status = N'Active'))
   OR (ISNULL(@classification, N'Internal') <> N'Restricted'
       AND EXISTS (SELECT 1
                   FROM   grac_practice.evidence_link l
                   JOIN   grac_practice.practice_task t
                          ON l.target_type = N'Task' AND t.task_id = l.target_id
                   WHERE  l.evidence_item_id = @evidence_item_id
                     AND  l.status = N'Active'));
GO

-- =====================================================================
-- 3. Migrate task_attachment
--    One item per distinct file per organisation (reusing a 476 item
--    whose current version is the identical file); one link per
--    attachment, pinned to that file, with the task's period. The task's
--    uploader owns a new item; the 192 description becomes the link note.
-- =====================================================================
DECLARE @a_id BIGINT, @a_task BIGINT, @a_org BIGINT, @a_pi BIGINT, @a_name NVARCHAR(500),
        @a_desc NVARCHAR(1000), @a_emp BIGINT, @a_dt DATETIME2, @a_hash VARBINARY(32),
        @a_period DATE, @item_id BIGINT, @file_id BIGINT, @migrated INT = 0, @reused INT = 0;

DECLARE pm477 CURSOR LOCAL FAST_FORWARD FOR
    SELECT a.task_attachment_id, a.task_id, t.organization_id, t.linked_instance_id,
           a.file_name, a.evidence_description, a.uploaded_by_employee_id, a.uploaded_dt,
           HASHBYTES('SHA2_256', a.file_data), p.period_date
    FROM   grac_practice.task_attachment a
    JOIN   grac_practice.practice_task t ON t.task_id = a.task_id
    CROSS  APPLY grac_practice.fn_pm_task_evidence_period(a.task_id) p
    WHERE  NOT EXISTS (SELECT 1 FROM grac_practice.evidence_link l
                        WHERE l.legacy_task_attachment_id = a.task_attachment_id)
    ORDER  BY a.task_attachment_id;

OPEN pm477;
FETCH NEXT FROM pm477 INTO @a_id, @a_task, @a_org, @a_pi, @a_name, @a_desc, @a_emp, @a_dt, @a_hash, @a_period;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRAN;

    SELECT @item_id = NULL, @file_id = NULL;
    SELECT TOP 1 @item_id = f.evidence_item_id, @file_id = f.evidence_file_id
    FROM   grac_practice.evidence_item_file f
    JOIN   grac_practice.evidence_item i ON i.evidence_item_id = f.evidence_item_id
    WHERE  f.organization_id = @a_org
      AND  f.file_sha256 = @a_hash
      AND  f.is_current = 1
      AND  i.status = N'Active'
    ORDER  BY f.evidence_file_id;

    IF @item_id IS NULL
    BEGIN
        INSERT grac_practice.evidence_item
            (organization_id, evidence_title, owner_employee_id, classification, status,
             created_by_employee_id, entered_by, entered_dt)
        VALUES
            (@a_org, LEFT(@a_name, 300), @a_emp, N'Internal', N'Active',
             @a_emp, N'migration-477', ISNULL(@a_dt, SYSUTCDATETIME()));
        SET @item_id = SCOPE_IDENTITY();

        INSERT grac_practice.evidence_item_file
            (evidence_item_id, organization_id, version_no, is_current, file_name, content_type,
             file_size_bytes, file_sha256, file_data, version_note,
             uploaded_by_employee_id, uploaded_by, uploaded_dt)
        SELECT @item_id, @a_org, 1, 1, a.file_name, a.content_type,
               a.file_size_bytes, @a_hash, a.file_data, N'Migrated from Task Centre evidence (192).',
               a.uploaded_by_employee_id, N'migration-477', a.uploaded_dt
        FROM   grac_practice.task_attachment a
        WHERE  a.task_attachment_id = @a_id;
        SET @file_id = SCOPE_IDENTITY();

        INSERT grac_practice.practice_audit_trace(entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
        SELECT N'evidence-item', @item_id, N'MIGRATE', NULL,
               (SELECT @a_id AS legacyTaskAttachmentId, @a_task AS taskId, @a_name AS fileName
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
               N'Active', N'migration-477';
        SET @migrated = @migrated + 1;
    END
    ELSE
        SET @reused = @reused + 1;

    -- The same file attached twice to one task: one active link.
    INSERT grac_practice.evidence_link
        (organization_id, evidence_item_id, evidence_file_id, target_type, target_id,
         practice_instance_id, link_note, period_from, period_to, status,
         linked_by_employee_id, linked_by, linked_dt, removed_by, removed_dt, legacy_task_attachment_id)
    SELECT @a_org, @item_id, @file_id, N'Task', @a_task,
           @a_pi, @a_desc, @a_period, @a_period,
           CASE WHEN dup.found = 1 THEN N'Removed' ELSE N'Active' END,
           @a_emp, N'migration-477', ISNULL(@a_dt, SYSUTCDATETIME()),
           CASE WHEN dup.found = 1 THEN N'migration-477' END,
           CASE WHEN dup.found = 1 THEN SYSUTCDATETIME() END,
           @a_id
    FROM  (SELECT CASE WHEN EXISTS (SELECT 1 FROM grac_practice.evidence_link l
                                     WHERE l.target_type = N'Task' AND l.target_id = @a_task
                                       AND l.evidence_item_id = @item_id AND l.status = N'Active')
                       THEN 1 ELSE 0 END AS found) dup;

    COMMIT;

    FETCH NEXT FROM pm477 INTO @a_id, @a_task, @a_org, @a_pi, @a_name, @a_desc, @a_emp, @a_dt, @a_hash, @a_period;
END
CLOSE pm477;
DEALLOCATE pm477;

PRINT '477: task attachments migrated -- new items = ' + CAST(@migrated AS NVARCHAR(20))
    + ', identical files linked to an existing item = ' + CAST(@reused AS NVARCHAR(20));
GO

-- =====================================================================
-- 4. Task evidence procedures
-- =====================================================================

-- ---------------------------------------------------------------------
-- 4a. sp_task_evidence_candidates -- "Select from Evidence Center" for
--     one task. Active items the caller can see. Linkable = 0, with the
--     reason, when the item's validity does not cover the task's period
--     date (agreed rule) or it is already on this task.
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE grac_practice.sp_task_evidence_candidates
    @task_id            BIGINT,
    @organization_id    BIGINT,
    @caller_employee_id BIGINT        = NULL,
    @caller_is_admin    BIT           = 0,
    @search             NVARCHAR(200) = NULL,
    @evidence_type_id   INT           = NULL,
    @page_number        INT           = 1,
    @page_size          INT           = 10
AS
BEGIN
    SET NOCOUNT ON;

    IF @task_id IS NULL OR @organization_id IS NULL
        THROW 52860, 'Organization and task are both required.', 1;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.practice_task t
                    WHERE t.task_id = @task_id AND t.organization_id = @organization_id)
        THROW 52861, 'That task was not found in this organization.', 1;

    SET @page_number = CASE WHEN ISNULL(@page_number, 0) < 1 THEN 1 ELSE @page_number END;
    SET @page_size   = CASE WHEN ISNULL(@page_size, 0) < 1 THEN 10 WHEN @page_size > 100 THEN 100 ELSE @page_size END;

    DECLARE @period DATE = (SELECT period_date FROM grac_practice.fn_pm_task_evidence_period(@task_id));
    DECLARE @today  DATE = CONVERT(DATE, SYSUTCDATETIME());
    DECLARE @s NVARCHAR(200) = NULLIF(LTRIM(RTRIM(@search)), N'');
    DECLARE @period_text NVARCHAR(10) = CONVERT(NVARCHAR(10), @period, 23);

    SELECT i.evidence_item_id     AS EvidenceItemId,
           i.evidence_title       AS EvidenceTitle,
           i.evidence_type_id     AS EvidenceTypeId,
           et.evidence_type_name  AS EvidenceType,
           i.evidence_description AS EvidenceDescription,
           ow.employee_name       AS OwnerName,
           i.valid_from           AS ValidFrom,
           i.valid_to             AS ValidTo,
           CASE WHEN i.valid_to IS NULL THEN N'NoExpiry'
                WHEN i.valid_to < @today THEN N'Expired'
                WHEN i.valid_to <= DATEADD(DAY, 30, @today) THEN N'Expiring'
                ELSE N'Valid' END AS ValidityState,
           i.classification       AS Classification,
           f.evidence_file_id     AS CurrentFileId,
           f.version_no           AS CurrentVersionNo,
           f.file_name            AS FileName,
           f.file_size_bytes      AS FileSizeBytes,
           f.uploaded_dt          AS LastUploadedDt,
           u.used_in_count        AS UsedInCount,
           @period                AS PeriodDate,
           CAST(CASE WHEN al.linked = 1 THEN 1 ELSE 0 END AS BIT) AS AlreadyLinked,
           CAST(CASE WHEN al.linked = 1 OR cv.covers = 0 THEN 0 ELSE 1 END AS BIT) AS Linkable,
           CASE WHEN al.linked = 1 THEN N'Already attached to this task.'
                WHEN cv.covers = 0 THEN N'Not valid on ' + @period_text + N' (the period of this task).'
                END                AS NotLinkableReason,
           COUNT(*) OVER ()        AS TotalRows
    FROM   grac_practice.evidence_item i
    CROSS  APPLY grac_practice.fn_pm_evidence_item_visible(
               i.evidence_item_id, i.owner_employee_id, i.created_by_employee_id,
               i.classification, @caller_employee_id, @caller_is_admin) v
    JOIN   grac_practice.evidence_item_file f
           ON f.evidence_item_id = i.evidence_item_id AND f.is_current = 1
    LEFT   JOIN grac_practice.evidence_type_master et ON et.evidence_type_id = i.evidence_type_id
    LEFT   JOIN grac_practice.organization_employee ow ON ow.employee_id = i.owner_employee_id
    OUTER  APPLY (SELECT COUNT(*) AS used_in_count FROM grac_practice.evidence_link l
                  WHERE l.evidence_item_id = i.evidence_item_id AND l.status = N'Active') u
    OUTER  APPLY (SELECT TOP 1 1 AS linked FROM grac_practice.evidence_link l2
                  WHERE l2.evidence_item_id = i.evidence_item_id AND l2.status = N'Active'
                    AND l2.target_type = N'Task' AND l2.target_id = @task_id) al
    CROSS  APPLY (SELECT CASE WHEN (i.valid_from IS NULL OR i.valid_from <= @period)
                               AND (i.valid_to   IS NULL OR i.valid_to   >= @period)
                              THEN 1 ELSE 0 END AS covers) cv
    WHERE  i.organization_id = @organization_id
      AND  i.status = N'Active'
      AND  (@evidence_type_id IS NULL OR i.evidence_type_id = @evidence_type_id)
      AND  (@s IS NULL
            OR i.evidence_title LIKE N'%' + @s + N'%'
            OR i.tags           LIKE N'%' + @s + N'%'
            OR f.file_name      LIKE N'%' + @s + N'%')
    ORDER  BY CASE WHEN al.linked = 1 OR cv.covers = 0 THEN 1 ELSE 0 END, i.evidence_title, i.evidence_item_id
    OFFSET (@page_number - 1) * @page_size ROWS FETCH NEXT @page_size ROWS ONLY;
END
GO

-- ---------------------------------------------------------------------
-- 4b. sp_task_evidence_link_add -- link an Evidence Center item to an
--     open task, pinned to its current version, for the task's period.
--     Result: TaskAttachmentId (= link id), EvidenceItemId, VersionNo,
--     Message.
-- ---------------------------------------------------------------------
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

-- ---------------------------------------------------------------------
-- 4c. sp_task_attachment_add (193 contract) -- "Upload new" on a task.
--   The file becomes an Evidence Center item (title = file name, owner =
--   uploader, Internal) linked to the task for its period. When the
--   uploader can already see an Active item whose current version is the
--   identical file and whose validity covers the period, that item is
--   linked instead (Reused = 1). New optional @caller_is_admin.
--   Result: TaskAttachmentId (= link id), FileSizeBytes, EvidenceItemId,
--           Reused, Message.
-- ---------------------------------------------------------------------
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

-- ---------------------------------------------------------------------
-- 4d. sp_task_attachment_get (193 contract) -- the pinned version of a
--     task link.
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE grac_practice.sp_task_attachment_get
    @task_attachment_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    IF @task_attachment_id IS NULL
        THROW 55612, 'sp_task_attachment_get: task_attachment_id is required.', 1;

    SELECT l.evidence_link_id AS TaskAttachmentId,
           l.target_id        AS TaskId,
           f.file_name        AS FileName,
           f.content_type     AS ContentType,
           f.file_size_bytes  AS FileSizeBytes,
           f.file_data        AS FileData
      FROM grac_practice.evidence_link l
      JOIN grac_practice.evidence_item_file f ON f.evidence_file_id = l.evidence_file_id
     WHERE l.evidence_link_id = @task_attachment_id
       AND l.target_type = N'Task'
       AND l.status = N'Active';
END;
GO

-- ---------------------------------------------------------------------
-- 4e. sp_evidence_center_get (476) -- Used in now lists tasks too:
--     TaskId / TaskNumber / TaskTitle / PeriodDate for a 'Task' link. A
--     link is shown (and counted as seen) when the caller can see its
--     instance or, for a task link, the task. Results 1 and 2 unchanged.
-- ---------------------------------------------------------------------
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
        -- 477: a link counts as seen through its instance, or, for a task
        -- link, through the task (both under View Data Scope).
        SELECT @seen = COUNT(*) FROM grac_practice.evidence_link l
         WHERE l.evidence_item_id = @evidence_item_id AND l.status = N'Active'
           AND (EXISTS (SELECT 1 FROM grac_practice.practice_instance pi
                         WHERE pi.practice_instance_id = l.practice_instance_id)
                OR (l.target_type = N'Task'
                    AND EXISTS (SELECT 1 FROM grac_practice.practice_task t WHERE t.task_id = l.target_id)));
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

    -- 3. used in (477: instance evidence rows and tasks the caller can see)
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
           t.task_id                AS TaskId,
           t.task_number            AS TaskNumber,
           t.subject_title          AS TaskTitle,
           l.period_from            AS PeriodDate,
           f.version_no             AS PinnedVersionNo,
           CAST(f.is_current AS BIT) AS IsLatest,
           l.link_note              AS LinkNote,
           COALESCE(lb.employee_name, l.linked_by) AS LinkedByName,
           l.linked_dt              AS LinkedDt
    FROM   grac_practice.evidence_link l
    LEFT   JOIN grac_practice.practice_instance pi ON pi.practice_instance_id = l.practice_instance_id
    LEFT   JOIN grac_practice.practice p ON p.practice_id = pi.practice_id
    LEFT   JOIN grac_practice.practice_instance_evidence e
           ON l.target_type = N'InstanceEvidence' AND e.evidence_id = l.target_id
    LEFT   JOIN grac_practice.evidence_type_master et ON et.evidence_type_id = e.evidence_type_id
    LEFT   JOIN grac_practice.practice_task t
           ON l.target_type = N'Task' AND t.task_id = l.target_id
    JOIN   grac_practice.evidence_item_file f ON f.evidence_file_id = l.evidence_file_id
    LEFT   JOIN grac_practice.organization_employee lb ON lb.employee_id = l.linked_by_employee_id
    WHERE  l.evidence_item_id = @evidence_item_id
      AND  l.status = N'Active'
      AND  @visible = 1
      AND  (pi.practice_instance_id IS NOT NULL OR t.task_id IS NOT NULL)
    ORDER  BY p.practice_code, pi.instance_code, l.target_type, l.linked_dt DESC, l.evidence_link_id;
END
GO

-- =====================================================================
-- 5. Expiry notifications ("evidence expiring in 30 days")
--    A notice is addressed to the item's owner and, when different, its
--    uploader. One row per item, recipient, notice and valid-to date, so
--    a sweep never raises the same notice twice and an extended validity
--    raises a fresh one later. The recipient reads them on My
--    Notifications.
-- =====================================================================
IF OBJECT_ID('grac_practice.evidence_expiry_notice','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.evidence_expiry_notice(
        evidence_notice_id    BIGINT IDENTITY(1,1) NOT NULL
            CONSTRAINT pk_pm_evidence_expiry_notice PRIMARY KEY,
        organization_id       BIGINT NOT NULL
            CONSTRAINT fk_pm_evidence_notice_org
                REFERENCES grac_practice.organization(organization_id),
        evidence_item_id      BIGINT NOT NULL
            CONSTRAINT fk_pm_evidence_notice_item
                REFERENCES grac_practice.evidence_item(evidence_item_id),
        recipient_employee_id BIGINT NOT NULL
            CONSTRAINT fk_pm_evidence_notice_recipient
                REFERENCES grac_practice.organization_employee(employee_id),
        notice_code           NVARCHAR(20) NOT NULL
            CONSTRAINT ck_pm_evidence_notice_code CHECK (notice_code IN (N'Expiring', N'Expired')),
        valid_to              DATE      NOT NULL,
        raised_dt             DATETIME2 NOT NULL
            CONSTRAINT df_pm_evidence_notice_dt DEFAULT SYSUTCDATETIME(),
        read_dt               DATETIME2 NULL,
        CONSTRAINT uq_pm_evidence_notice UNIQUE (evidence_item_id, recipient_employee_id, notice_code, valid_to)
    );
    CREATE INDEX ix_pm_evidence_notice_recipient
        ON grac_practice.evidence_expiry_notice(recipient_employee_id, read_dt)
        INCLUDE (organization_id, evidence_item_id, notice_code, valid_to, raised_dt);
    PRINT '477: evidence_expiry_notice created.';
END
GO

-- ---------------------------------------------------------------------
-- 5a. sp_evidence_expiry_sweep -- raises the notices. Idempotent.
--   Expiring: valid to between today and today + @days.
--   Expired : valid to in the last @days (an item that expired long
--             before the first sweep is not announced).
--   Active items only. Result: ExpiringRaised, ExpiredRaised.
--   Run by the API worker (TaskNotificationWorker, EvidenceExpiry pass)
--   or by SQL Agent: EXEC grac_practice.sp_evidence_expiry_sweep;
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE grac_practice.sp_evidence_expiry_sweep
    @organization_id BIGINT = NULL,   -- NULL = every organisation
    @days            INT    = 30
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @days = CASE WHEN ISNULL(@days, 0) < 1 THEN 30 ELSE @days END;
    DECLARE @today DATE = CONVERT(DATE, SYSUTCDATETIME());
    DECLARE @raised TABLE (notice_code NVARCHAR(20) NOT NULL);

    ;WITH due AS (
        SELECT i.evidence_item_id, i.organization_id, i.valid_to,
               CASE WHEN i.valid_to >= @today THEN N'Expiring' ELSE N'Expired' END AS notice_code,
               i.owner_employee_id, i.created_by_employee_id
        FROM   grac_practice.evidence_item i
        WHERE  i.status = N'Active'
          AND  i.valid_to IS NOT NULL
          AND  i.valid_to BETWEEN DATEADD(DAY, -@days, @today) AND DATEADD(DAY, @days, @today)
          AND  (@organization_id IS NULL OR i.organization_id = @organization_id)
    ), rcpt AS (
        SELECT d.evidence_item_id, d.organization_id, d.valid_to, d.notice_code, r.employee_id
        FROM   due d
        CROSS  APPLY (VALUES (d.owner_employee_id), (d.created_by_employee_id)) r(employee_id)
        WHERE  r.employee_id IS NOT NULL
    )
    INSERT grac_practice.evidence_expiry_notice
        (organization_id, evidence_item_id, recipient_employee_id, notice_code, valid_to, raised_dt)
    OUTPUT inserted.notice_code INTO @raised (notice_code)
    SELECT DISTINCT x.organization_id, x.evidence_item_id, x.employee_id, x.notice_code, x.valid_to, SYSUTCDATETIME()
    FROM   rcpt x
    JOIN   grac_practice.organization_employee oe
           ON oe.employee_id = x.employee_id AND oe.status = N'Active'
    WHERE  NOT EXISTS (SELECT 1 FROM grac_practice.evidence_expiry_notice n
                        WHERE n.evidence_item_id = x.evidence_item_id
                          AND n.recipient_employee_id = x.employee_id
                          AND n.notice_code = x.notice_code
                          AND n.valid_to = x.valid_to);

    SELECT ExpiringRaised = ISNULL(SUM(CASE WHEN notice_code = N'Expiring' THEN 1 ELSE 0 END), 0),
           ExpiredRaised  = ISNULL(SUM(CASE WHEN notice_code = N'Expired'  THEN 1 ELSE 0 END), 0)
    FROM   @raised;
END
GO

-- ---------------------------------------------------------------------
-- 5b. sp_evidence_expiry_notice_list -- one recipient's notices.
--   @status: Unread (default) / Read / All. UnreadCount = all unread of
--   the recipient (for the badge), whatever the filter.
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE grac_practice.sp_evidence_expiry_notice_list
    @recipient_employee_id BIGINT,
    @organization_id       BIGINT       = NULL,
    @status                NVARCHAR(10) = N'Unread',
    @page_number           INT          = 1,
    @page_size             INT          = 25
AS
BEGIN
    SET NOCOUNT ON;

    IF @recipient_employee_id IS NULL
        THROW 52866, 'The recipient is required.', 1;

    SET @status      = ISNULL(NULLIF(LTRIM(RTRIM(@status)), N''), N'Unread');
    SET @page_number = CASE WHEN ISNULL(@page_number, 0) < 1 THEN 1 ELSE @page_number END;
    SET @page_size   = CASE WHEN ISNULL(@page_size, 0) < 1 THEN 25 WHEN @page_size > 200 THEN 200 ELSE @page_size END;

    DECLARE @unread INT = (SELECT COUNT(*) FROM grac_practice.evidence_expiry_notice n
                            WHERE n.recipient_employee_id = @recipient_employee_id AND n.read_dt IS NULL
                              AND (@organization_id IS NULL OR n.organization_id = @organization_id));

    SELECT n.evidence_notice_id AS EvidenceNoticeId,
           n.organization_id    AS OrganizationId,
           n.evidence_item_id   AS EvidenceItemId,
           i.evidence_title     AS EvidenceTitle,
           i.status             AS EvidenceItemStatus,
           n.notice_code        AS NoticeCode,
           n.valid_to           AS ValidTo,
           i.valid_to           AS CurrentValidTo,
           CASE WHEN i.owner_employee_id = n.recipient_employee_id THEN N'Owner' ELSE N'Uploader' END AS WhyYou,
           (SELECT COUNT(*) FROM grac_practice.evidence_link l
             WHERE l.evidence_item_id = n.evidence_item_id AND l.status = N'Active') AS UsedInCount,
           n.raised_dt          AS RaisedDt,
           n.read_dt            AS ReadDt,
           @unread              AS UnreadCount,
           COUNT(*) OVER ()     AS TotalRows
    FROM   grac_practice.evidence_expiry_notice n
    JOIN   grac_practice.evidence_item i ON i.evidence_item_id = n.evidence_item_id
    WHERE  n.recipient_employee_id = @recipient_employee_id
      AND  (@organization_id IS NULL OR n.organization_id = @organization_id)
      AND  (@status = N'All'
            OR (@status = N'Unread' AND n.read_dt IS NULL)
            OR (@status = N'Read'   AND n.read_dt IS NOT NULL))
    ORDER  BY n.raised_dt DESC, n.evidence_notice_id DESC
    OFFSET (@page_number - 1) * @page_size ROWS FETCH NEXT @page_size ROWS ONLY;
END
GO

-- ---------------------------------------------------------------------
-- 5c. sp_evidence_expiry_notice_mark -- mark one notice (or all of the
--     recipient's, @evidence_notice_id NULL) read. Only the recipient's
--     own rows are touched. Result: MarkedCount.
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE grac_practice.sp_evidence_expiry_notice_mark
    @recipient_employee_id BIGINT,
    @evidence_notice_id    BIGINT = NULL,
    @organization_id       BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @recipient_employee_id IS NULL
        THROW 52866, 'The recipient is required.', 1;

    UPDATE grac_practice.evidence_expiry_notice
       SET read_dt = SYSUTCDATETIME()
     WHERE recipient_employee_id = @recipient_employee_id
       AND read_dt IS NULL
       AND (@evidence_notice_id IS NULL OR evidence_notice_id = @evidence_notice_id)
       AND (@organization_id    IS NULL OR organization_id    = @organization_id);

    SELECT @@ROWCOUNT AS MarkedCount;
END
GO

-- =====================================================================
-- 6. Re-issued bodies (only the marked parts change)
-- =====================================================================

-- ---------------------------------------------------------------------
-- 6a. sp_task_get (195 body) -- result 3 reads the task's links.
-- ---------------------------------------------------------------------
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

-- ---------------------------------------------------------------------
-- 6b. sp_task_completion_eligibility (473 body) -- the recurring-evidence
--     gate counts the task's links.
-- ---------------------------------------------------------------------
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
-- 7. Verification
-- =====================================================================
SELECT '477 evidence_link takes Task targets' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM sys.check_constraints
                          WHERE name = 'ck_pm_evidence_link_target'
                            AND parent_object_id = OBJECT_ID('grac_practice.evidence_link')
                            AND definition LIKE '%Task%')
             AND COL_LENGTH('grac_practice.evidence_link','legacy_task_attachment_id') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result_
UNION ALL
SELECT '477 procedures',
       CASE WHEN OBJECT_ID('grac_practice.sp_task_evidence_candidates','P')     IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_task_evidence_link_add','P')       IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_evidence_expiry_sweep','P')        IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_evidence_expiry_notice_list','P')  IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_evidence_expiry_notice_mark','P')  IS NOT NULL
             AND OBJECT_ID('grac_practice.fn_pm_task_evidence_period','IF')     IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '477 task procedures read links',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_task_get'))                    LIKE '%evidence_link%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_task_attachment_add'))         LIKE '%sp_evidence_item_store%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_task_attachment_get'))         LIKE '%evidence_link%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_task_completion_eligibility')) LIKE '%evidence_link%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_evidence_center_get'))         LIKE '%practice_task%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '477 every task_attachment migrated',
       CASE WHEN NOT EXISTS (
              SELECT 1 FROM grac_practice.task_attachment a
              WHERE NOT EXISTS (SELECT 1 FROM grac_practice.evidence_link l
                                 WHERE l.legacy_task_attachment_id = a.task_attachment_id))
            THEN 'PASS' ELSE 'FAIL' END;
GO

-- Links per organisation and target.
SELECT l.organization_id, l.target_type,
       ActiveLinks = SUM(CASE WHEN l.status = N'Active' THEN 1 ELSE 0 END),
       Items       = COUNT(DISTINCT l.evidence_item_id)
FROM   grac_practice.evidence_link l
GROUP  BY l.organization_id, l.target_type
ORDER  BY l.organization_id, l.target_type;
GO

-- First expiry sweep (the API worker repeats it hourly).
EXEC grac_practice.sp_evidence_expiry_sweep;
GO

PRINT '477 complete.';
GO
