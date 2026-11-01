-- =====================================================================
-- 476_evidence_center_rollback.sql
--
-- Reverses 476:
--   1. Hands Operationalize's files back to practice_instance_evidence_
--      attachment (473), so nothing attached after 476 is lost:
--        * an active link with no 473 row (attached / linked after 476)
--          gets one, carrying the PINNED version's bytes; the link is
--          marked with it, so a re-run does not copy it twice;
--        * a migrated 473 row whose link was removed after 476 is set to
--          Removed (removed_by 'rollback-476').
--      A link moved to a newer version keeps the 473 row it came from
--      (the version that was attached at the time).
--   2. Re-issues, verbatim, the 473 bodies 476 replaced:
--        sp_resolve_evidence_list
--        sp_resolve_evidence_attachment_add / _list / _get / _remove
--   3. Drops the procedures and functions 476 added.
--   4. Removes the evidence-center menu row and its permission rows.
--   5. evidence_link / evidence_item_file / evidence_item are dropped ONLY
--      when every item came from the 476 migration (its files are still in
--      the 473 table). An item uploaded in the Evidence Center after 476
--      keeps the tables in place, and the script says so.
--
-- Turn the API / Web change off first (or deploy the previous build): the
-- screens call the procedures this drops. Also remove the evidence-center
-- rows from 274_menu_master_seed.sql.
-- SAFE TO RE-RUN. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET NOEXEC OFF;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

-- =====================================================================
-- 1. Files back to the 473 table
-- =====================================================================
IF OBJECT_ID('grac_practice.evidence_link','U') IS NOT NULL
   AND OBJECT_ID('grac_practice.practice_instance_evidence_attachment','U') IS NOT NULL
BEGIN
    DECLARE @l_id BIGINT, @new_att BIGINT, @copied INT = 0;
    DECLARE rb476 CURSOR LOCAL FAST_FORWARD FOR
        SELECT l.evidence_link_id
        FROM   grac_practice.evidence_link l
        WHERE  l.target_type = N'InstanceEvidence'
          AND  l.status = N'Active'
          AND  l.legacy_attachment_id IS NULL
          AND  l.practice_instance_id IS NOT NULL
        ORDER  BY l.evidence_link_id;
    OPEN rb476;
    FETCH NEXT FROM rb476 INTO @l_id;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRAN;
        INSERT grac_practice.practice_instance_evidence_attachment
            (organization_id, practice_instance_id, evidence_id, file_name, content_type,
             file_size_bytes, file_data, attachment_description, status,
             uploaded_by_employee_id, uploaded_by, uploaded_dt)
        SELECT l.organization_id, l.practice_instance_id, l.target_id, f.file_name, f.content_type,
               f.file_size_bytes, f.file_data, l.link_note, N'Active',
               l.linked_by_employee_id, l.linked_by, l.linked_dt
        FROM   grac_practice.evidence_link l
        JOIN   grac_practice.evidence_item_file f ON f.evidence_file_id = l.evidence_file_id
        WHERE  l.evidence_link_id = @l_id;
        SET @new_att = SCOPE_IDENTITY();

        UPDATE grac_practice.evidence_link
           SET legacy_attachment_id = @new_att
         WHERE evidence_link_id = @l_id;
        COMMIT;
        SET @copied = @copied + 1;
        FETCH NEXT FROM rb476 INTO @l_id;
    END
    CLOSE rb476;
    DEALLOCATE rb476;
    PRINT '476 rollback: files copied back to the 473 table = ' + CAST(@copied AS NVARCHAR(20));

    UPDATE a
       SET status     = N'Removed',
           removed_by = N'rollback-476',
           removed_dt = COALESCE(l.removed_dt, SYSUTCDATETIME())
    FROM   grac_practice.practice_instance_evidence_attachment a
    JOIN   grac_practice.evidence_link l ON l.legacy_attachment_id = a.evidence_attachment_id
    WHERE  a.status = N'Active'
      AND  l.status = N'Removed'
      AND  ISNULL(l.removed_by, N'') <> N'migration-476';
    PRINT '476 rollback: 473 rows set to Removed (unlinked after 476) = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
END
GO

-- =====================================================================
-- 2. The 473 bodies
-- =====================================================================
-- ---------------------------------------------------------------------
-- 2a. sp_resolve_evidence_list (473 body)
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
                  THEN 1 ELSE 0 END AS BIT) AS IsResolved,

        -- 473: is this proof produced once (attached here, at
        -- implementation) or again for every scheduled occurrence?
        -- Read from the organisation's copy of the published spec through
        -- vw_pm_instance_evidence_cadence; 'Default' = nothing published
        -- (organisation-defined evidence), which is treated as Recurring.
        cad.EvidenceCadence       AS EvidenceCadence,
        cad.EvidenceCadenceLabel  AS EvidenceCadenceLabel,
        cad.CadenceSource         AS EvidenceCadenceSource,
        (SELECT COUNT(*) FROM grac_practice.practice_instance_evidence_attachment ea
          WHERE ea.evidence_id = e.evidence_id AND ea.status = N'Active') AS AttachmentCount
    FROM   grac_practice.practice_instance_evidence e
    LEFT   JOIN grac_practice.vw_pm_instance_evidence_cadence cad
           ON cad.evidence_id = e.evidence_id
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
-- 2b. sp_resolve_evidence_attachment_add (473 body)
--
--   A file attached to an evidence row at implementation. Only ONE-TIME
--   evidence takes one here: recurring evidence is produced again for
--   every occurrence and is attached to that occurrence's task (see
--   sp_task_completion_eligibility).
--   Result: EvidenceAttachmentId, FileSizeBytes.
-- ---------------------------------------------------------------------
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
    @organization_id         BIGINT         = NULL
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

    DECLARE @row_organization_id BIGINT, @cadence NVARCHAR(30);
    SELECT @row_organization_id = e.organization_id,
           @cadence             = c.EvidenceCadence
    FROM   grac_practice.practice_instance_evidence e
    LEFT   JOIN grac_practice.vw_pm_instance_evidence_cadence c ON c.evidence_id = e.evidence_id
    WHERE  e.evidence_id          = @evidence_id
      AND  e.practice_instance_id = @practice_instance_id
      AND  e.status = N'Active'
      AND  (@organization_id IS NULL OR e.organization_id = @organization_id);
    SET @organization_id = @row_organization_id;

    -- Scoped to the instance the caller opened, the sp_resolve_evidence_save way.
    IF @organization_id IS NULL
        THROW 52763, 'sp_resolve_evidence_attachment_add: that evidence row was not found on this practice instance.', 1;
    IF ISNULL(@cadence, N'Recurring') <> N'OneTime'
        THROW 52764, 'Only one-time evidence is attached on Operationalize. Recurring evidence is attached to each scheduled task when it is completed.', 1;

    -- The uploader comes from the session (Web tier). Kept only when it is
    -- an employee of this organisation; the name stamp is kept either way.
    IF @uploaded_by_employee_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee oe
                        WHERE oe.employee_id = @uploaded_by_employee_id
                          AND oe.organization_id = @organization_id)
        SET @uploaded_by_employee_id = NULL;

    DECLARE @size BIGINT = DATALENGTH(@file_data), @attachment_id BIGINT;

    BEGIN TRAN;

    INSERT grac_practice.practice_instance_evidence_attachment
        (organization_id, practice_instance_id, evidence_id, file_name, content_type,
         file_size_bytes, file_data, attachment_description, status,
         uploaded_by_employee_id, uploaded_by, uploaded_dt)
    VALUES
        (@organization_id, @practice_instance_id, @evidence_id, LTRIM(RTRIM(@file_name)), @content_type,
         @size, @file_data, NULLIF(LTRIM(RTRIM(@attachment_description)), N''), N'Active',
         @uploaded_by_employee_id, ISNULL(@actor, N'system'), SYSUTCDATETIME());

    SET @attachment_id = SCOPE_IDENTITY();

    INSERT grac_practice.practice_audit_trace(entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    SELECT N'practice-instance-evidence-attachment', @attachment_id, N'CREATE', NULL,
           (SELECT @practice_instance_id AS practiceInstanceId, @evidence_id AS evidenceId,
                   LTRIM(RTRIM(@file_name)) AS fileName, @size AS fileSizeBytes
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
           N'Active', ISNULL(@actor, N'system');

    COMMIT;

    SELECT @attachment_id AS EvidenceAttachmentId, @size AS FileSizeBytes;
END
GO

-- ---------------------------------------------------------------------
-- 2c. sp_resolve_evidence_attachment_list (473 body) -- metadata only (no file_data)
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE grac_practice.sp_resolve_evidence_attachment_list
    @practice_instance_id BIGINT,
    @organization_id      BIGINT = NULL   -- NULL = no check (see _add)
AS
BEGIN
    SET NOCOUNT ON;

    IF @practice_instance_id IS NULL
        THROW 52765, 'sp_resolve_evidence_attachment_list: practice_instance_id is required.', 1;

    SELECT a.evidence_attachment_id  AS EvidenceAttachmentId,
           a.evidence_id             AS EvidenceId,
           a.file_name               AS FileName,
           a.content_type            AS ContentType,
           a.file_size_bytes         AS FileSizeBytes,
           a.attachment_description  AS AttachmentDescription,
           a.uploaded_by_employee_id AS UploadedByEmployeeId,
           COALESCE(emp.employee_name, a.uploaded_by) AS UploadedByName,
           a.uploaded_dt             AS UploadedDt
    FROM   grac_practice.practice_instance_evidence_attachment a
    LEFT   JOIN grac_practice.organization_employee emp
           ON emp.employee_id = a.uploaded_by_employee_id
    WHERE  a.practice_instance_id = @practice_instance_id
      AND  a.status = N'Active'
      AND  (@organization_id IS NULL OR a.organization_id = @organization_id)
    ORDER  BY a.evidence_id, a.uploaded_dt DESC, a.evidence_attachment_id DESC;
END
GO

-- ---------------------------------------------------------------------
-- 2d. sp_resolve_evidence_attachment_get (473 body) -- one file, for download.
--     Scoped to the instance: an id from another instance returns nothing.
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE grac_practice.sp_resolve_evidence_attachment_get
    @practice_instance_id   BIGINT,
    @evidence_attachment_id BIGINT,
    @organization_id        BIGINT = NULL   -- NULL = no check (see _add)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT a.evidence_attachment_id AS EvidenceAttachmentId,
           a.evidence_id            AS EvidenceId,
           a.file_name              AS FileName,
           a.content_type           AS ContentType,
           a.file_size_bytes        AS FileSizeBytes,
           a.file_data              AS FileData
    FROM   grac_practice.practice_instance_evidence_attachment a
    WHERE  a.evidence_attachment_id = @evidence_attachment_id
      AND  a.practice_instance_id   = @practice_instance_id
      AND  a.status = N'Active'
      AND  (@organization_id IS NULL OR a.organization_id = @organization_id);
END
GO

-- ---------------------------------------------------------------------
-- 2e. sp_resolve_evidence_attachment_remove (473 body) -- soft remove, audited.
--     The bytes stay (status = Removed) so the audit trail can still
--     say what was there.
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE grac_practice.sp_resolve_evidence_attachment_remove
    @practice_instance_id   BIGINT,
    @evidence_attachment_id BIGINT,
    @actor                  NVARCHAR(100) = N'system',
    @organization_id        BIGINT        = NULL   -- NULL = no check (see _add)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @practice_instance_id IS NULL OR @evidence_attachment_id IS NULL
        THROW 52766, 'sp_resolve_evidence_attachment_remove: practice instance and attachment are both required.', 1;

    DECLARE @file_name NVARCHAR(500), @evidence_id BIGINT;
    SELECT @file_name = a.file_name, @evidence_id = a.evidence_id
    FROM   grac_practice.practice_instance_evidence_attachment a
    WHERE  a.evidence_attachment_id = @evidence_attachment_id
      AND  a.practice_instance_id   = @practice_instance_id
      AND  a.status = N'Active'
      AND  (@organization_id IS NULL OR a.organization_id = @organization_id);

    IF @evidence_id IS NULL
        THROW 52767, 'sp_resolve_evidence_attachment_remove: that attachment was not found on this practice instance.', 1;

    BEGIN TRAN;

    UPDATE grac_practice.practice_instance_evidence_attachment
       SET status     = N'Removed',
           removed_by = ISNULL(@actor, N'system'),
           removed_dt = SYSUTCDATETIME()
     WHERE evidence_attachment_id = @evidence_attachment_id;

    INSERT grac_practice.practice_audit_trace(entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    SELECT N'practice-instance-evidence-attachment', @evidence_attachment_id, N'REMOVE',
           (SELECT @practice_instance_id AS practiceInstanceId, @evidence_id AS evidenceId,
                   @file_name AS fileName, N'Active' AS status
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
           (SELECT N'Removed' AS status FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
           N'Active', ISNULL(@actor, N'system');

    COMMIT;

    SELECT CAST(1 AS BIT) AS Success, N'Attachment removed.' AS Message;
END
GO

-- =====================================================================
-- 3. Procedures and functions 476 added
-- =====================================================================
DROP PROCEDURE IF EXISTS grac_practice.sp_evidence_link_refresh;
DROP PROCEDURE IF EXISTS grac_practice.sp_evidence_link_add;
DROP PROCEDURE IF EXISTS grac_practice.sp_evidence_link_candidates;
DROP PROCEDURE IF EXISTS grac_practice.sp_evidence_center_lookups;
DROP PROCEDURE IF EXISTS grac_practice.sp_evidence_center_status;
DROP PROCEDURE IF EXISTS grac_practice.sp_evidence_center_save;
DROP PROCEDURE IF EXISTS grac_practice.sp_evidence_center_upload;
DROP PROCEDURE IF EXISTS grac_practice.sp_evidence_item_store;
DROP PROCEDURE IF EXISTS grac_practice.sp_evidence_center_file_get;
DROP PROCEDURE IF EXISTS grac_practice.sp_evidence_center_get;
DROP PROCEDURE IF EXISTS grac_practice.sp_evidence_center_list;
GO
DROP FUNCTION IF EXISTS grac_practice.fn_pm_evidence_item_editable;
DROP FUNCTION IF EXISTS grac_practice.fn_pm_evidence_item_visible;
GO

-- =====================================================================
-- 4. Menu
-- =====================================================================
IF OBJECT_ID('grac_practice.menu_master','U') IS NOT NULL
BEGIN
    DELETE p
      FROM grac_practice.organization_role_menu_permission p
      JOIN grac_practice.menu_master m ON m.menu_id = p.menu_id
     WHERE m.menu_key = N'evidence-center';
    PRINT '476 rollback: permission rows removed = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
    DELETE FROM grac_practice.menu_master WHERE menu_key = N'evidence-center';
    PRINT '476 rollback: menu row removed = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
END
GO

-- =====================================================================
-- 5. Tables -- only when every item came from the 476 migration
-- =====================================================================
IF OBJECT_ID('grac_practice.evidence_item','U') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM grac_practice.evidence_item i
                WHERE NOT EXISTS (SELECT 1 FROM grac_practice.practice_audit_trace t
                                   WHERE t.entity_type = N'evidence-item'
                                     AND t.entity_id   = i.evidence_item_id
                                     AND t.action_type = N'MIGRATE'))
        PRINT '476 rollback: Evidence Center holds items uploaded after 476 -- evidence_link, evidence_item_file and evidence_item KEPT. Drop them by hand once those files are no longer needed.';
    ELSE
    BEGIN
        DROP TABLE IF EXISTS grac_practice.evidence_link;
        DROP TABLE IF EXISTS grac_practice.evidence_item_file;
        DROP TABLE IF EXISTS grac_practice.evidence_item;
        PRINT '476 rollback: Evidence Center tables dropped (every item was migrated from 473).';
    END
END
GO

-- =====================================================================
-- Verification
-- =====================================================================
SELECT '476 rollback: attachment procedures read the 473 table' AS Check_,
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_resolve_evidence_attachment_list')) LIKE '%practice_instance_evidence_attachment%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_resolve_evidence_list')) NOT LIKE '%evidence_link%'
            THEN 'PASS' ELSE 'FAIL' END AS Result_
UNION ALL
SELECT '476 rollback: Evidence Center procedures removed',
       CASE WHEN OBJECT_ID('grac_practice.sp_evidence_center_list','P') IS NULL
             AND OBJECT_ID('grac_practice.sp_evidence_link_add','P') IS NULL
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '476 rollback: menu row removed',
       CASE WHEN NOT EXISTS (SELECT 1 FROM grac_practice.menu_master WHERE menu_key = N'evidence-center')
            THEN 'PASS' ELSE 'FAIL' END;
GO

PRINT '476 rollback complete.';
GO
