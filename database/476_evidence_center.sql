-- =====================================================================
-- 476_evidence_center.sql
--
-- REQUEST (2026-10-18)
-- --------------------
--   "Evidence Center - Architecture Plan" (Claude Doc, agreed 2026-10-18),
--   Phase 1. A file is uploaded ONCE into an organisation-level Evidence
--   Center; every place that uses it holds only a LINK. Phase 1 covers
--   Operationalize one-time evidence (473) and the Evidence Center screen.
--
--   Decisions (agreed 2026-10-18):
--     * Visibility: an item is visible to its uploader and owner, to users
--       who can see an instance it is linked to (View Data Scope, 415/460)
--       and to organisation admins. "Restricted" items: owner and admins
--       only.
--     * Recurring tasks: older evidence may be referenced only when its
--       validity covers the occurrence period (Phase 2 -- the link already
--       carries period_from / period_to for it).
--     * Version pin: a link stays on the version that was linked; a newer
--       version is offered as an update.
--     * Phase 1 scope: Operationalize only. Task completion follows in
--       Phase 2.
--
-- WHAT THIS FILE DOES
-- -------------------
--   1. Tables
--        evidence_item       the organisation-level entry (title, type,
--                            description, owner, validity, classification,
--                            tags, status Active / Retired / Deleted)
--        evidence_item_file  its versions (version_no, is_current,
--                            SHA-256, bytes) -- document_upload_file shape
--        evidence_link       item + PINNED version + target. Phase 1
--                            target: 'InstanceEvidence' = one
--                            practice_instance_evidence row (target_id =
--                            evidence_id). legacy_attachment_id = the 473
--                            row it was migrated from.
--   2. fn_pm_evidence_item_visible -- the visibility rule above, in ONE
--      place. "Can see a linked instance" reads grac_practice.
--      practice_instance, so the View Data Scope row-level security policy
--      (415) decides it on a connection that carries the reader.
--   3. Migration of the active 473 attachments: one item per distinct file
--      (SHA-256) per organisation, one link per attachment (pinned to that
--      file). Re-runnable: an attachment already migrated is skipped.
--      practice_instance_evidence_attachment is NOT dropped and NOT
--      changed (plan: no phase drops an old table straight away).
--   4. Evidence Center procedures
--        sp_evidence_center_list      grid (filters, paging, Used in count)
--        sp_evidence_center_get       item + versions + Used in
--        sp_evidence_center_file_get  one version, for download
--        sp_evidence_center_upload    new item, or a new version of one;
--                                     an identical file already in the
--                                     Evidence Center is reported, not
--                                     stored again (unless asked)
--        sp_evidence_center_save      metadata
--        sp_evidence_center_status    Retire / Restore / Delete (Delete
--                                     only with no active link)
--        sp_evidence_center_lookups   evidence types + employees
--   5. Linking (Operationalize)
--        sp_evidence_link_candidates  picker list for one evidence row
--        sp_evidence_link_add         link an existing item (pins current)
--        sp_evidence_link_refresh     move a link to the latest version
--      and the 473 procedures re-issued over links, same contract
--      (EvidenceAttachmentId is now the link id):
--        sp_resolve_evidence_attachment_add    stores the file as an item
--                                              (or links the identical one
--                                              the uploader can already see)
--        sp_resolve_evidence_attachment_list   + item / version columns
--        sp_resolve_evidence_attachment_get    the PINNED version
--        sp_resolve_evidence_attachment_remove UNLINK -- the file stays in
--                                              the Evidence Center
--      sp_resolve_evidence_list re-issued: AttachmentCount counts links.
--   6. Menu row 'evidence-center' (Policies & Documents -> Evidence
--      Center, display_order 15) + permissions for every active role of
--      every active organisation (the 458 way). 274 edited as well.
--
-- ERROR NUMBERS: 52780-52799, 52850-52869 (user-facing sentences).
--
-- DEPENDS ON: 473 (practice_instance_evidence_attachment, the cadence
--   view, the attachment procedures), 475 (cadence view fix), 415 (View
--   Data Scope), 384 (nav-documents).
-- Rollback: 476_evidence_center_rollback.sql
-- SAFE TO RE-RUN. ASCII-only. SQL Server 2016+ (HASHBYTES on MAX).
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOEXEC OFF;
GO

DECLARE @prereqs_ok BIT = 1;
IF OBJECT_ID('grac_practice.practice_instance_evidence_attachment','U') IS NULL
BEGIN PRINT 'ABORT (476): practice_instance_evidence_attachment missing. Run 473 first.'; SET @prereqs_ok = 0; END
IF @prereqs_ok = 1 AND OBJECT_ID('grac_practice.vw_pm_instance_evidence_cadence','V') IS NULL
BEGIN PRINT 'ABORT (476): vw_pm_instance_evidence_cadence missing. Run 473 / 475 first.'; SET @prereqs_ok = 0; END
IF @prereqs_ok = 1 AND OBJECT_ID('grac_practice.menu_master','U') IS NULL
BEGIN PRINT 'ABORT (476): grac_practice.menu_master missing.'; SET @prereqs_ok = 0; END
IF @prereqs_ok = 1 AND NOT EXISTS (SELECT 1 FROM grac_practice.menu_master WHERE menu_key = N'nav-documents')
BEGIN PRINT 'ABORT (476): nav-documents (Policies & Documents) menu row missing. Run 384 first.'; SET @prereqs_ok = 0; END
IF @prereqs_ok = 0
BEGIN
    RAISERROR('476_evidence_center: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. Tables
-- =====================================================================
IF OBJECT_ID('grac_practice.evidence_item','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.evidence_item(
        evidence_item_id       BIGINT IDENTITY(1,1) NOT NULL
            CONSTRAINT pk_pm_evidence_item PRIMARY KEY,
        organization_id        BIGINT NOT NULL
            CONSTRAINT fk_pm_evidence_item_org
                REFERENCES grac_practice.organization(organization_id),
        evidence_title         NVARCHAR(300)  NOT NULL,
        evidence_type_id       INT            NULL
            CONSTRAINT fk_pm_evidence_item_type
                REFERENCES grac_practice.evidence_type_master(evidence_type_id),
        evidence_description   NVARCHAR(2000) NULL,
        owner_employee_id      BIGINT         NULL
            CONSTRAINT fk_pm_evidence_item_owner
                REFERENCES grac_practice.organization_employee(employee_id),
        valid_from             DATE           NULL,
        valid_to               DATE           NULL,
        -- Internal / Confidential: visibility rule as agreed (Confidential
        -- is a label in Phase 1). Restricted: owner and admins only.
        classification         NVARCHAR(30)   NOT NULL
            CONSTRAINT df_pm_evidence_item_class DEFAULT N'Internal'
            CONSTRAINT ck_pm_evidence_item_class
                CHECK (classification IN (N'Internal', N'Confidential', N'Restricted')),
        tags                   NVARCHAR(500)  NULL,
        -- Active / Retired (kept, cannot be newly linked) / Deleted (only
        -- when no active link; hidden everywhere, bytes kept for the audit).
        status                 NVARCHAR(30)   NOT NULL
            CONSTRAINT df_pm_evidence_item_status DEFAULT N'Active'
            CONSTRAINT ck_pm_evidence_item_status
                CHECK (status IN (N'Active', N'Retired', N'Deleted')),
        created_by_employee_id BIGINT         NULL
            CONSTRAINT fk_pm_evidence_item_creator
                REFERENCES grac_practice.organization_employee(employee_id),
        entered_by             NVARCHAR(100)  NOT NULL,
        entered_dt             DATETIME2      NOT NULL
            CONSTRAINT df_pm_evidence_item_dt DEFAULT SYSUTCDATETIME(),
        updated_by             NVARCHAR(100)  NULL,
        updated_dt             DATETIME2      NULL,
        CONSTRAINT ck_pm_evidence_item_validity
            CHECK (valid_from IS NULL OR valid_to IS NULL OR valid_to >= valid_from)
    );
    CREATE INDEX ix_pm_evidence_item_org
        ON grac_practice.evidence_item(organization_id, status)
        INCLUDE (evidence_title, evidence_type_id, owner_employee_id, created_by_employee_id, valid_to, classification);
    PRINT '476: evidence_item created.';
END
GO

-- The fat VARBINARY lives here, so list queries never read it.
IF OBJECT_ID('grac_practice.evidence_item_file','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.evidence_item_file(
        evidence_file_id        BIGINT IDENTITY(1,1) NOT NULL
            CONSTRAINT pk_pm_evidence_item_file PRIMARY KEY,
        evidence_item_id        BIGINT NOT NULL
            CONSTRAINT fk_pm_evidence_item_file_item
                REFERENCES grac_practice.evidence_item(evidence_item_id),
        organization_id         BIGINT NOT NULL,
        version_no              INT            NOT NULL,
        is_current              BIT            NOT NULL
            CONSTRAINT df_pm_evidence_item_file_current DEFAULT 1,
        file_name               NVARCHAR(500)  NOT NULL,
        content_type            NVARCHAR(200)  NULL,
        file_size_bytes         BIGINT         NOT NULL,
        file_sha256             VARBINARY(32)  NOT NULL,
        file_data               VARBINARY(MAX) NOT NULL,
        version_note            NVARCHAR(1000) NULL,
        uploaded_by_employee_id BIGINT         NULL
            CONSTRAINT fk_pm_evidence_item_file_uploader
                REFERENCES grac_practice.organization_employee(employee_id),
        uploaded_by             NVARCHAR(100)  NOT NULL,
        uploaded_dt             DATETIME2      NOT NULL
            CONSTRAINT df_pm_evidence_item_file_dt DEFAULT SYSUTCDATETIME(),
        CONSTRAINT uq_pm_evidence_item_file_version UNIQUE (evidence_item_id, version_no)
    );
    CREATE UNIQUE INDEX ux_pm_evidence_item_file_current
        ON grac_practice.evidence_item_file(evidence_item_id)
        WHERE is_current = 1;
    CREATE INDEX ix_pm_evidence_item_file_hash
        ON grac_practice.evidence_item_file(organization_id, file_sha256)
        INCLUDE (evidence_item_id, is_current, version_no);
    PRINT '476: evidence_item_file created.';
END
GO

IF OBJECT_ID('grac_practice.evidence_link','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.evidence_link(
        evidence_link_id      BIGINT IDENTITY(1,1) NOT NULL
            CONSTRAINT pk_pm_evidence_link PRIMARY KEY,
        organization_id       BIGINT NOT NULL
            CONSTRAINT fk_pm_evidence_link_org
                REFERENCES grac_practice.organization(organization_id),
        evidence_item_id      BIGINT NOT NULL
            CONSTRAINT fk_pm_evidence_link_item
                REFERENCES grac_practice.evidence_item(evidence_item_id),
        -- The version this link shows (pinned at linking; moved only by
        -- sp_evidence_link_refresh).
        evidence_file_id      BIGINT NOT NULL
            CONSTRAINT fk_pm_evidence_link_file
                REFERENCES grac_practice.evidence_item_file(evidence_file_id),
        -- Phase 1: 'InstanceEvidence' (target_id = practice_instance_evidence.
        -- evidence_id). Phase 2 adds the scheduled task.
        target_type           NVARCHAR(40)   NOT NULL
            CONSTRAINT ck_pm_evidence_link_target CHECK (target_type IN (N'InstanceEvidence')),
        target_id             BIGINT         NOT NULL,
        practice_instance_id  BIGINT         NULL
            CONSTRAINT fk_pm_evidence_link_instance
                REFERENCES grac_practice.practice_instance(practice_instance_id),
        link_note             NVARCHAR(1000) NULL,
        -- Phase 2 (recurring evidence: validity must cover the period).
        period_from           DATE           NULL,
        period_to             DATE           NULL,
        status                NVARCHAR(30)   NOT NULL
            CONSTRAINT df_pm_evidence_link_status DEFAULT N'Active'
            CONSTRAINT ck_pm_evidence_link_status CHECK (status IN (N'Active', N'Removed')),
        linked_by_employee_id BIGINT         NULL
            CONSTRAINT fk_pm_evidence_link_linker
                REFERENCES grac_practice.organization_employee(employee_id),
        linked_by             NVARCHAR(100)  NOT NULL,
        linked_dt             DATETIME2      NOT NULL
            CONSTRAINT df_pm_evidence_link_dt DEFAULT SYSUTCDATETIME(),
        removed_by            NVARCHAR(100)  NULL,
        removed_dt            DATETIME2      NULL,
        legacy_attachment_id  BIGINT         NULL
            CONSTRAINT fk_pm_evidence_link_legacy
                REFERENCES grac_practice.practice_instance_evidence_attachment(evidence_attachment_id)
    );
    -- One active link of an item per target.
    CREATE UNIQUE INDEX ux_pm_evidence_link_active
        ON grac_practice.evidence_link(target_type, target_id, evidence_item_id)
        WHERE status = N'Active';
    CREATE UNIQUE INDEX ux_pm_evidence_link_legacy
        ON grac_practice.evidence_link(legacy_attachment_id)
        WHERE legacy_attachment_id IS NOT NULL;
    CREATE INDEX ix_pm_evidence_link_item
        ON grac_practice.evidence_link(evidence_item_id, status)
        INCLUDE (practice_instance_id, target_type, target_id, evidence_file_id);
    CREATE INDEX ix_pm_evidence_link_instance
        ON grac_practice.evidence_link(practice_instance_id, target_type, status)
        INCLUDE (target_id, evidence_item_id, evidence_file_id);
    PRINT '476: evidence_link created.';
END
GO

-- =====================================================================
-- 2. Visibility -- the agreed rule, in one place.
--    Returns one row when the caller may see the item:
--      admin                                   -> every item
--      owner                                   -> own items (any class)
--      uploader (created_by), not Restricted   -> items they created
--      not Restricted, linked to an instance the caller can see.
--    "Can see" is grac_practice.practice_instance under the View Data
--    Scope policy (415): on a connection that carries the reader
--    (ViewScopeSession) the EXISTS only finds instances in their scope.
-- =====================================================================
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

-- Edit rights (metadata, new version, retire / delete): admin, owner, or
-- the uploader of a non-Restricted item. Users who see an item only
-- through a linked instance may view and link it, not change it.
CREATE OR ALTER FUNCTION grac_practice.fn_pm_evidence_item_editable
    (@owner_employee_id      BIGINT,
     @created_by_employee_id BIGINT,
     @classification         NVARCHAR(30),
     @caller_employee_id     BIGINT,
     @caller_is_admin        BIT)
RETURNS TABLE
AS
RETURN
SELECT CAST(1 AS BIT) AS is_editable
WHERE  ISNULL(@caller_is_admin, 0) = 1
   OR (@caller_employee_id IS NOT NULL AND @owner_employee_id = @caller_employee_id)
   OR (ISNULL(@classification, N'Internal') <> N'Restricted'
       AND @caller_employee_id IS NOT NULL
       AND @created_by_employee_id = @caller_employee_id);
GO

-- =====================================================================
-- 3. Migrate the active 473 attachments.
--    One item per distinct file (SHA-256) per organisation; one link per
--    attachment, pinned to that file. The item takes the first upload's
--    name, the evidence row's type and the uploader as owner; the 473
--    description becomes the link note. Removed attachments stay where
--    they are (the audit trail already describes them).
-- =====================================================================
DECLARE @a_id BIGINT, @a_org BIGINT, @a_pi BIGINT, @a_ev BIGINT, @a_name NVARCHAR(500),
        @a_ctype NVARCHAR(200), @a_size BIGINT, @a_desc NVARCHAR(1000), @a_emp BIGINT,
        @a_by NVARCHAR(100), @a_dt DATETIME2, @a_hash VARBINARY(32), @a_type INT,
        @item_id BIGINT, @file_id BIGINT, @migrated INT = 0, @reused INT = 0;

DECLARE pm476 CURSOR LOCAL FAST_FORWARD FOR
    SELECT a.evidence_attachment_id, a.organization_id, a.practice_instance_id, a.evidence_id,
           a.file_name, a.content_type, a.file_size_bytes, a.attachment_description,
           a.uploaded_by_employee_id, a.uploaded_by, a.uploaded_dt,
           HASHBYTES('SHA2_256', a.file_data), e.evidence_type_id
    FROM   grac_practice.practice_instance_evidence_attachment a
    LEFT   JOIN grac_practice.practice_instance_evidence e ON e.evidence_id = a.evidence_id
    WHERE  a.status = N'Active'
      AND  NOT EXISTS (SELECT 1 FROM grac_practice.evidence_link l
                        WHERE l.legacy_attachment_id = a.evidence_attachment_id)
    ORDER  BY a.evidence_attachment_id;

OPEN pm476;
FETCH NEXT FROM pm476 INTO @a_id, @a_org, @a_pi, @a_ev, @a_name, @a_ctype, @a_size, @a_desc,
                           @a_emp, @a_by, @a_dt, @a_hash, @a_type;
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
            (organization_id, evidence_title, evidence_type_id, owner_employee_id,
             classification, status, created_by_employee_id, entered_by, entered_dt)
        VALUES
            (@a_org, LEFT(@a_name, 300),
             CASE WHEN EXISTS (SELECT 1 FROM grac_practice.evidence_type_master t WHERE t.evidence_type_id = @a_type)
                  THEN @a_type END,
             @a_emp, N'Internal', N'Active', @a_emp, ISNULL(@a_by, N'system'), ISNULL(@a_dt, SYSUTCDATETIME()));
        SET @item_id = SCOPE_IDENTITY();

        INSERT grac_practice.evidence_item_file
            (evidence_item_id, organization_id, version_no, is_current, file_name, content_type,
             file_size_bytes, file_sha256, file_data, version_note,
             uploaded_by_employee_id, uploaded_by, uploaded_dt)
        SELECT @item_id, @a_org, 1, 1, a.file_name, a.content_type,
               a.file_size_bytes, @a_hash, a.file_data, N'Migrated from Operationalize (473).',
               a.uploaded_by_employee_id, ISNULL(a.uploaded_by, N'system'), a.uploaded_dt
        FROM   grac_practice.practice_instance_evidence_attachment a
        WHERE  a.evidence_attachment_id = @a_id;
        SET @file_id = SCOPE_IDENTITY();

        INSERT grac_practice.practice_audit_trace(entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
        SELECT N'evidence-item', @item_id, N'MIGRATE', NULL,
               (SELECT @a_id AS legacyAttachmentId, @a_name AS fileName FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
               N'Active', N'migration-476';
        SET @migrated = @migrated + 1;
    END
    ELSE
        SET @reused = @reused + 1;

    -- The same file attached twice to one evidence row: one link is enough.
    IF NOT EXISTS (SELECT 1 FROM grac_practice.evidence_link l
                    WHERE l.target_type = N'InstanceEvidence' AND l.target_id = @a_ev
                      AND l.evidence_item_id = @item_id AND l.status = N'Active')
        INSERT grac_practice.evidence_link
            (organization_id, evidence_item_id, evidence_file_id, target_type, target_id,
             practice_instance_id, link_note, status, linked_by_employee_id, linked_by, linked_dt,
             legacy_attachment_id)
        VALUES
            (@a_org, @item_id, @file_id, N'InstanceEvidence', @a_ev,
             @a_pi, @a_desc, N'Active', @a_emp, ISNULL(@a_by, N'system'), ISNULL(@a_dt, SYSUTCDATETIME()),
             @a_id);
    ELSE
        INSERT grac_practice.evidence_link
            (organization_id, evidence_item_id, evidence_file_id, target_type, target_id,
             practice_instance_id, link_note, status, linked_by_employee_id, linked_by, linked_dt,
             removed_by, removed_dt, legacy_attachment_id)
        VALUES
            (@a_org, @item_id, @file_id, N'InstanceEvidence', @a_ev,
             @a_pi, @a_desc, N'Removed', @a_emp, ISNULL(@a_by, N'system'), ISNULL(@a_dt, SYSUTCDATETIME()),
             N'migration-476', SYSUTCDATETIME(), @a_id);

    COMMIT;

    FETCH NEXT FROM pm476 INTO @a_id, @a_org, @a_pi, @a_ev, @a_name, @a_ctype, @a_size, @a_desc,
                               @a_emp, @a_by, @a_dt, @a_hash, @a_type;
END
CLOSE pm476;
DEALLOCATE pm476;

PRINT '476: 473 attachments migrated -- new items = ' + CAST(@migrated AS NVARCHAR(20))
    + ', identical files linked to an existing item = ' + CAST(@reused AS NVARCHAR(20));
GO

-- =====================================================================
-- 4. Evidence Center procedures
--    Every procedure takes the organisation the Web tier checked the
--    caller against and the caller (employee id + admin flag) the Web
--    tier stamped from the session. Visibility / edit rights: the two
--    functions above.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 4a. sp_evidence_center_list -- the grid.
--   @validity: Valid (incl. no expiry) / Expiring / Expired / NULL = all
--   @usage   : Used / Unused / NULL = all
--   @status  : Active (default) / Retired / All (Deleted never shows)
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE grac_practice.sp_evidence_center_list
    @organization_id    BIGINT,
    @caller_employee_id BIGINT        = NULL,
    @caller_is_admin    BIT           = 0,
    @search             NVARCHAR(200) = NULL,
    @evidence_type_id   INT           = NULL,
    @owner_employee_id  BIGINT        = NULL,
    @validity           NVARCHAR(20)  = NULL,
    @usage              NVARCHAR(20)  = NULL,
    @status             NVARCHAR(20)  = N'Active',
    @expiring_days      INT           = 30,
    @page_number        INT           = 1,
    @page_size          INT           = 25
AS
BEGIN
    SET NOCOUNT ON;

    IF @organization_id IS NULL
        THROW 52780, 'Select an organization.', 1;

    SET @page_number   = CASE WHEN ISNULL(@page_number, 0) < 1 THEN 1 ELSE @page_number END;
    SET @page_size     = CASE WHEN ISNULL(@page_size, 0) < 1 THEN 25 WHEN @page_size > 200 THEN 200 ELSE @page_size END;
    SET @expiring_days = CASE WHEN ISNULL(@expiring_days, 0) < 1 THEN 30 ELSE @expiring_days END;
    SET @status        = ISNULL(NULLIF(LTRIM(RTRIM(@status)), N''), N'Active');

    DECLARE @today DATE = CONVERT(DATE, SYSUTCDATETIME());
    DECLARE @s NVARCHAR(200) = NULLIF(LTRIM(RTRIM(@search)), N'');

    ;WITH base AS (
        SELECT i.evidence_item_id, i.evidence_title, i.evidence_type_id, i.evidence_description,
               i.owner_employee_id, i.created_by_employee_id, i.valid_from, i.valid_to,
               i.classification, i.tags, i.status, i.entered_dt, i.updated_dt,
               f.evidence_file_id, f.version_no, f.file_name, f.file_size_bytes, f.content_type,
               f.uploaded_dt,
               u.used_in_count,
               CASE WHEN i.valid_to IS NULL THEN N'NoExpiry'
                    WHEN i.valid_to < @today THEN N'Expired'
                    WHEN i.valid_to <= DATEADD(DAY, @expiring_days, @today) THEN N'Expiring'
                    ELSE N'Valid' END AS validity_state,
               CASE WHEN ed.is_editable = 1 THEN CAST(1 AS BIT) ELSE CAST(0 AS BIT) END AS can_edit
        FROM   grac_practice.evidence_item i
        CROSS  APPLY grac_practice.fn_pm_evidence_item_visible(
                   i.evidence_item_id, i.owner_employee_id, i.created_by_employee_id,
                   i.classification, @caller_employee_id, @caller_is_admin) v
        OUTER  APPLY grac_practice.fn_pm_evidence_item_editable(
                   i.owner_employee_id, i.created_by_employee_id,
                   i.classification, @caller_employee_id, @caller_is_admin) ed
        LEFT   JOIN grac_practice.evidence_item_file f
               ON f.evidence_item_id = i.evidence_item_id AND f.is_current = 1
        OUTER  APPLY (SELECT COUNT(*) AS used_in_count
                      FROM   grac_practice.evidence_link l
                      WHERE  l.evidence_item_id = i.evidence_item_id
                        AND  l.status = N'Active') u
        WHERE  i.organization_id = @organization_id
          AND  i.status <> N'Deleted'
          AND  (@status = N'All' OR i.status = @status)
          AND  (@evidence_type_id  IS NULL OR i.evidence_type_id  = @evidence_type_id)
          AND  (@owner_employee_id IS NULL OR i.owner_employee_id = @owner_employee_id)
          AND  (@s IS NULL
                OR i.evidence_title LIKE N'%' + @s + N'%'
                OR i.tags           LIKE N'%' + @s + N'%'
                OR f.file_name      LIKE N'%' + @s + N'%')
    )
    SELECT b.evidence_item_id       AS EvidenceItemId,
           b.evidence_title         AS EvidenceTitle,
           b.evidence_type_id       AS EvidenceTypeId,
           et.evidence_type_name    AS EvidenceType,
           b.evidence_description   AS EvidenceDescription,
           b.owner_employee_id      AS OwnerEmployeeId,
           ow.employee_name         AS OwnerName,
           b.valid_from             AS ValidFrom,
           b.valid_to               AS ValidTo,
           b.validity_state         AS ValidityState,
           b.classification         AS Classification,
           b.tags                   AS Tags,
           b.status                 AS Status,
           b.evidence_file_id       AS CurrentFileId,
           b.version_no             AS CurrentVersionNo,
           b.file_name              AS FileName,
           b.file_size_bytes        AS FileSizeBytes,
           b.content_type           AS ContentType,
           b.uploaded_dt            AS LastUploadedDt,
           b.used_in_count          AS UsedInCount,
           b.can_edit               AS CanEdit,
           COUNT(*) OVER ()         AS TotalRows
    FROM   base b
    LEFT   JOIN grac_practice.evidence_type_master et ON et.evidence_type_id = b.evidence_type_id
    LEFT   JOIN grac_practice.organization_employee ow ON ow.employee_id = b.owner_employee_id
    WHERE  (@validity IS NULL OR @validity = N''
            OR (@validity = N'Valid'    AND b.validity_state IN (N'Valid', N'NoExpiry'))
            OR (@validity = N'Expiring' AND b.validity_state = N'Expiring')
            OR (@validity = N'Expired'  AND b.validity_state = N'Expired'))
      AND  (@usage IS NULL OR @usage = N''
            OR (@usage = N'Used'   AND b.used_in_count > 0)
            OR (@usage = N'Unused' AND b.used_in_count = 0))
    ORDER  BY b.evidence_title, b.evidence_item_id
    OFFSET (@page_number - 1) * @page_size ROWS FETCH NEXT @page_size ROWS ONLY;
END
GO

-- ---------------------------------------------------------------------
-- 4b. sp_evidence_center_get -- item, versions, Used in.
--   Result 1: the item (no row = not found or not visible).
--   Result 2: versions, newest first, with how many active links pin each.
--   Result 3: Used in -- the active links on instances the caller can see
--             (practice_instance under View Data Scope). UsedInCount in
--             result 1 is every active link; HiddenUsageCount the rest.
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

-- ---------------------------------------------------------------------
-- 4c. sp_evidence_center_file_get -- one version, for download.
--     Nothing comes back for an item the caller cannot see.
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE grac_practice.sp_evidence_center_file_get
    @organization_id    BIGINT,
    @evidence_file_id   BIGINT,
    @caller_employee_id BIGINT = NULL,
    @caller_is_admin    BIT    = 0
AS
BEGIN
    SET NOCOUNT ON;

    SELECT f.evidence_file_id AS EvidenceFileId,
           f.evidence_item_id AS EvidenceItemId,
           f.version_no       AS VersionNo,
           f.file_name        AS FileName,
           f.content_type     AS ContentType,
           f.file_size_bytes  AS FileSizeBytes,
           f.file_data        AS FileData
    FROM   grac_practice.evidence_item_file f
    JOIN   grac_practice.evidence_item i ON i.evidence_item_id = f.evidence_item_id
    CROSS  APPLY grac_practice.fn_pm_evidence_item_visible(
               i.evidence_item_id, i.owner_employee_id, i.created_by_employee_id,
               i.classification, @caller_employee_id, @caller_is_admin) v
    WHERE  f.evidence_file_id = @evidence_file_id
      AND  i.organization_id  = @organization_id
      AND  i.status <> N'Deleted';
END
GO

-- ---------------------------------------------------------------------
-- 4d. sp_evidence_item_store -- INTERNAL. Stores a file as a new item
--     (@evidence_item_id NULL) or as the next version of one. No
--     permission or duplicate checks: the callers make them.
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE grac_practice.sp_evidence_item_store
    @organization_id        BIGINT,
    @evidence_item_id       BIGINT         OUTPUT,
    @file_name              NVARCHAR(500),
    @content_type           NVARCHAR(200)  = NULL,
    @file_data              VARBINARY(MAX),
    @file_sha256            VARBINARY(32),
    @version_note           NVARCHAR(1000) = NULL,
    @evidence_title         NVARCHAR(300)  = NULL,
    @evidence_type_id       INT            = NULL,
    @evidence_description   NVARCHAR(2000) = NULL,
    @owner_employee_id      BIGINT         = NULL,
    @valid_from             DATE           = NULL,
    @valid_to               DATE           = NULL,
    @classification         NVARCHAR(30)   = N'Internal',
    @tags                   NVARCHAR(500)  = NULL,
    @caller_employee_id     BIGINT         = NULL,
    @actor                  NVARCHAR(100)  = N'system',
    @evidence_file_id       BIGINT         OUTPUT,
    @version_no             INT            OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @size BIGINT = DATALENGTH(@file_data);
    SET @actor = ISNULL(NULLIF(LTRIM(RTRIM(@actor)), N''), N'system');

    BEGIN TRAN;

    IF @evidence_item_id IS NULL
    BEGIN
        INSERT grac_practice.evidence_item
            (organization_id, evidence_title, evidence_type_id, evidence_description,
             owner_employee_id, valid_from, valid_to, classification, tags, status,
             created_by_employee_id, entered_by, entered_dt)
        VALUES
            (@organization_id,
             COALESCE(NULLIF(LTRIM(RTRIM(@evidence_title)), N''), LEFT(LTRIM(RTRIM(@file_name)), 300)),
             @evidence_type_id, NULLIF(LTRIM(RTRIM(@evidence_description)), N''),
             COALESCE(@owner_employee_id, @caller_employee_id), @valid_from, @valid_to,
             ISNULL(@classification, N'Internal'), NULLIF(LTRIM(RTRIM(@tags)), N''), N'Active',
             @caller_employee_id, @actor, SYSUTCDATETIME());
        SET @evidence_item_id = SCOPE_IDENTITY();
        SET @version_no = 1;

        INSERT grac_practice.practice_audit_trace(entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
        SELECT N'evidence-item', @evidence_item_id, N'CREATE', NULL,
               (SELECT i.evidence_title AS title, i.evidence_type_id AS evidenceTypeId,
                       i.owner_employee_id AS ownerEmployeeId, i.classification AS classification,
                       i.valid_from AS validFrom, i.valid_to AS validTo
                FROM grac_practice.evidence_item i WHERE i.evidence_item_id = @evidence_item_id
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
               N'Active', @actor;
    END
    ELSE
    BEGIN
        SELECT @version_no = ISNULL(MAX(version_no), 0) + 1
        FROM   grac_practice.evidence_item_file WITH (UPDLOCK, HOLDLOCK)
        WHERE  evidence_item_id = @evidence_item_id;

        UPDATE grac_practice.evidence_item_file
           SET is_current = 0
         WHERE evidence_item_id = @evidence_item_id AND is_current = 1;

        UPDATE grac_practice.evidence_item
           SET updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE evidence_item_id = @evidence_item_id;
    END

    INSERT grac_practice.evidence_item_file
        (evidence_item_id, organization_id, version_no, is_current, file_name, content_type,
         file_size_bytes, file_sha256, file_data, version_note,
         uploaded_by_employee_id, uploaded_by, uploaded_dt)
    VALUES
        (@evidence_item_id, @organization_id, @version_no, 1, LTRIM(RTRIM(@file_name)), @content_type,
         @size, @file_sha256, @file_data, NULLIF(LTRIM(RTRIM(@version_note)), N''),
         @caller_employee_id, @actor, SYSUTCDATETIME());
    SET @evidence_file_id = SCOPE_IDENTITY();

    INSERT grac_practice.practice_audit_trace(entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    SELECT N'evidence-item-file', @evidence_file_id, N'CREATE', NULL,
           (SELECT @evidence_item_id AS evidenceItemId, @version_no AS versionNo,
                   LTRIM(RTRIM(@file_name)) AS fileName, @size AS fileSizeBytes
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
           N'Active', @actor;

    COMMIT;
END
GO

-- ---------------------------------------------------------------------
-- 4e. sp_evidence_center_upload -- Upload new (an item), or New version
--     (@evidence_item_id given).
--   New item: an identical file (SHA-256) that is the current version of
--   an Active item the caller can see is REPORTED, not stored again
--   (Duplicate = 1, with that item), unless @allow_duplicate = 1. An
--   identical file the caller cannot see is never revealed.
--   New version: caller must have edit rights; the item must be Active;
--   a file identical to the current version is refused.
--   Result: Duplicate, EvidenceItemId, EvidenceFileId, VersionNo,
--           DuplicateItemId, DuplicateTitle, DuplicateVersionNo.
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE grac_practice.sp_evidence_center_upload
    @organization_id      BIGINT,
    @evidence_item_id     BIGINT         = NULL,
    @file_name            NVARCHAR(500),
    @content_type         NVARCHAR(200)  = NULL,
    @file_data            VARBINARY(MAX),
    @version_note         NVARCHAR(1000) = NULL,
    @evidence_title       NVARCHAR(300)  = NULL,
    @evidence_type_id     INT            = NULL,
    @evidence_description NVARCHAR(2000) = NULL,
    @owner_employee_id    BIGINT         = NULL,
    @valid_from           DATE           = NULL,
    @valid_to             DATE           = NULL,
    @classification       NVARCHAR(30)   = NULL,
    @tags                 NVARCHAR(500)  = NULL,
    @allow_duplicate      BIT            = 0,
    @caller_employee_id   BIGINT         = NULL,
    @caller_is_admin      BIT            = 0,
    @actor                NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @organization_id IS NULL
        THROW 52780, 'Select an organization.', 1;
    IF @file_name IS NULL OR LEN(LTRIM(RTRIM(@file_name))) = 0
        THROW 52782, 'A file name is required.', 1;
    IF @file_data IS NULL OR DATALENGTH(@file_data) = 0
        THROW 52783, 'The file is empty.', 1;

    -- The caller is kept only when an employee of this organisation.
    IF @caller_employee_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee oe
                        WHERE oe.employee_id = @caller_employee_id
                          AND oe.organization_id = @organization_id)
        SET @caller_employee_id = NULL;

    DECLARE @hash VARBINARY(32) = HASHBYTES('SHA2_256', @file_data);
    DECLARE @file_id BIGINT, @version_no INT;

    IF @evidence_item_id IS NOT NULL
    BEGIN
        DECLARE @item_status NVARCHAR(30), @editable BIT = 0;
        SELECT @item_status = i.status,
               @editable    = CASE WHEN ed.is_editable = 1 THEN 1 ELSE 0 END
        FROM   grac_practice.evidence_item i
        OUTER  APPLY grac_practice.fn_pm_evidence_item_editable(
                   i.owner_employee_id, i.created_by_employee_id,
                   i.classification, @caller_employee_id, @caller_is_admin) ed
        WHERE  i.evidence_item_id = @evidence_item_id
          AND  i.organization_id  = @organization_id
          AND  i.status <> N'Deleted';

        IF @item_status IS NULL
            THROW 52784, 'That evidence item was not found in this organization.', 1;
        IF @editable = 0
            THROW 52785, 'Only the owner, the uploader or an organization admin can change this evidence item.', 1;
        IF @item_status <> N'Active'
            THROW 52786, 'This evidence item is retired. Restore it before uploading a new version.', 1;
        IF EXISTS (SELECT 1 FROM grac_practice.evidence_item_file f
                    WHERE f.evidence_item_id = @evidence_item_id AND f.is_current = 1
                      AND f.file_sha256 = @hash)
            THROW 52787, 'This file is identical to the current version. Nothing was uploaded.', 1;

        EXEC grac_practice.sp_evidence_item_store
             @organization_id = @organization_id, @evidence_item_id = @evidence_item_id OUTPUT,
             @file_name = @file_name, @content_type = @content_type, @file_data = @file_data,
             @file_sha256 = @hash, @version_note = @version_note,
             @caller_employee_id = @caller_employee_id, @actor = @actor,
             @evidence_file_id = @file_id OUTPUT, @version_no = @version_no OUTPUT;

        SELECT CAST(0 AS BIT) AS Duplicate, @evidence_item_id AS EvidenceItemId,
               @file_id AS EvidenceFileId, @version_no AS VersionNo,
               CAST(NULL AS BIGINT) AS DuplicateItemId, CAST(NULL AS NVARCHAR(300)) AS DuplicateTitle,
               CAST(NULL AS INT) AS DuplicateVersionNo;
        RETURN;
    END

    -- New item: metadata rules.
    SET @classification = ISNULL(NULLIF(LTRIM(RTRIM(@classification)), N''), N'Internal');
    IF @classification NOT IN (N'Internal', N'Confidential', N'Restricted')
        THROW 52788, 'Classification must be Internal, Confidential or Restricted.', 1;
    IF @valid_from IS NOT NULL AND @valid_to IS NOT NULL AND @valid_to < @valid_from
        THROW 52789, 'Valid to cannot be before Valid from.', 1;
    IF @evidence_type_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM grac_practice.evidence_type_master t WHERE t.evidence_type_id = @evidence_type_id)
        THROW 52790, 'That evidence type does not exist.', 1;
    IF @owner_employee_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee oe
                        WHERE oe.employee_id = @owner_employee_id
                          AND oe.organization_id = @organization_id
                          AND oe.status = N'Active')
        THROW 52791, 'The owner must be an active employee of this organization.', 1;

    IF ISNULL(@allow_duplicate, 0) = 0
    BEGIN
        DECLARE @dup_item BIGINT, @dup_title NVARCHAR(300), @dup_version INT;
        SELECT TOP 1 @dup_item = i.evidence_item_id, @dup_title = i.evidence_title, @dup_version = f.version_no
        FROM   grac_practice.evidence_item_file f
        JOIN   grac_practice.evidence_item i ON i.evidence_item_id = f.evidence_item_id
        CROSS  APPLY grac_practice.fn_pm_evidence_item_visible(
                   i.evidence_item_id, i.owner_employee_id, i.created_by_employee_id,
                   i.classification, @caller_employee_id, @caller_is_admin) v
        WHERE  f.organization_id = @organization_id
          AND  f.file_sha256 = @hash
          AND  f.is_current = 1
          AND  i.status = N'Active'
        ORDER  BY i.evidence_item_id;

        IF @dup_item IS NOT NULL
        BEGIN
            SELECT CAST(1 AS BIT) AS Duplicate, CAST(NULL AS BIGINT) AS EvidenceItemId,
                   CAST(NULL AS BIGINT) AS EvidenceFileId, CAST(NULL AS INT) AS VersionNo,
                   @dup_item AS DuplicateItemId, @dup_title AS DuplicateTitle, @dup_version AS DuplicateVersionNo;
            RETURN;
        END
    END

    DECLARE @new_item BIGINT = NULL;
    EXEC grac_practice.sp_evidence_item_store
         @organization_id = @organization_id, @evidence_item_id = @new_item OUTPUT,
         @file_name = @file_name, @content_type = @content_type, @file_data = @file_data,
         @file_sha256 = @hash, @version_note = @version_note,
         @evidence_title = @evidence_title, @evidence_type_id = @evidence_type_id,
         @evidence_description = @evidence_description, @owner_employee_id = @owner_employee_id,
         @valid_from = @valid_from, @valid_to = @valid_to, @classification = @classification,
         @tags = @tags, @caller_employee_id = @caller_employee_id, @actor = @actor,
         @evidence_file_id = @file_id OUTPUT, @version_no = @version_no OUTPUT;

    SELECT CAST(0 AS BIT) AS Duplicate, @new_item AS EvidenceItemId,
           @file_id AS EvidenceFileId, @version_no AS VersionNo,
           CAST(NULL AS BIGINT) AS DuplicateItemId, CAST(NULL AS NVARCHAR(300)) AS DuplicateTitle,
           CAST(NULL AS INT) AS DuplicateVersionNo;
END
GO

-- ---------------------------------------------------------------------
-- 4f. sp_evidence_center_save -- metadata of an item. Edit rights only.
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE grac_practice.sp_evidence_center_save
    @organization_id      BIGINT,
    @evidence_item_id     BIGINT,
    @evidence_title       NVARCHAR(300),
    @evidence_type_id     INT            = NULL,
    @evidence_description NVARCHAR(2000) = NULL,
    @owner_employee_id    BIGINT         = NULL,
    @valid_from           DATE           = NULL,
    @valid_to             DATE           = NULL,
    @classification       NVARCHAR(30)   = N'Internal',
    @tags                 NVARCHAR(500)  = NULL,
    @caller_employee_id   BIGINT         = NULL,
    @caller_is_admin      BIT            = 0,
    @actor                NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @organization_id IS NULL OR @evidence_item_id IS NULL
        THROW 52781, 'Organization and evidence item are both required.', 1;
    IF @evidence_title IS NULL OR LEN(LTRIM(RTRIM(@evidence_title))) = 0
        THROW 52792, 'A title is required.', 1;

    SET @classification = ISNULL(NULLIF(LTRIM(RTRIM(@classification)), N''), N'Internal');
    IF @classification NOT IN (N'Internal', N'Confidential', N'Restricted')
        THROW 52788, 'Classification must be Internal, Confidential or Restricted.', 1;
    IF @valid_from IS NOT NULL AND @valid_to IS NOT NULL AND @valid_to < @valid_from
        THROW 52789, 'Valid to cannot be before Valid from.', 1;
    IF @evidence_type_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM grac_practice.evidence_type_master t WHERE t.evidence_type_id = @evidence_type_id)
        THROW 52790, 'That evidence type does not exist.', 1;
    IF @owner_employee_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee oe
                        WHERE oe.employee_id = @owner_employee_id
                          AND oe.organization_id = @organization_id
                          AND oe.status = N'Active')
        THROW 52791, 'The owner must be an active employee of this organization.', 1;

    DECLARE @found BIT = 0, @editable BIT = 0;
    SELECT @found = 1, @editable = CASE WHEN ed.is_editable = 1 THEN 1 ELSE 0 END
    FROM   grac_practice.evidence_item i
    OUTER  APPLY grac_practice.fn_pm_evidence_item_editable(
               i.owner_employee_id, i.created_by_employee_id,
               i.classification, @caller_employee_id, @caller_is_admin) ed
    WHERE  i.evidence_item_id = @evidence_item_id
      AND  i.organization_id  = @organization_id
      AND  i.status <> N'Deleted';

    IF @found = 0
        THROW 52784, 'That evidence item was not found in this organization.', 1;
    IF @editable = 0
        THROW 52785, 'Only the owner, the uploader or an organization admin can change this evidence item.', 1;

    SET @actor = ISNULL(NULLIF(LTRIM(RTRIM(@actor)), N''), N'system');

    DECLARE @before NVARCHAR(MAX) = (
        SELECT i.evidence_title AS title, i.evidence_type_id AS evidenceTypeId,
               i.evidence_description AS description, i.owner_employee_id AS ownerEmployeeId,
               i.valid_from AS validFrom, i.valid_to AS validTo, i.classification AS classification,
               i.tags AS tags
        FROM grac_practice.evidence_item i WHERE i.evidence_item_id = @evidence_item_id
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    BEGIN TRAN;

    UPDATE grac_practice.evidence_item
       SET evidence_title       = LTRIM(RTRIM(@evidence_title)),
           evidence_type_id     = @evidence_type_id,
           evidence_description = NULLIF(LTRIM(RTRIM(@evidence_description)), N''),
           owner_employee_id    = @owner_employee_id,
           valid_from           = @valid_from,
           valid_to             = @valid_to,
           classification       = @classification,
           tags                 = NULLIF(LTRIM(RTRIM(@tags)), N''),
           updated_by           = @actor,
           updated_dt           = SYSUTCDATETIME()
     WHERE evidence_item_id = @evidence_item_id;

    INSERT grac_practice.practice_audit_trace(entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    SELECT N'evidence-item', @evidence_item_id, N'UPDATE', @before,
           (SELECT i.evidence_title AS title, i.evidence_type_id AS evidenceTypeId,
                   i.evidence_description AS description, i.owner_employee_id AS ownerEmployeeId,
                   i.valid_from AS validFrom, i.valid_to AS validTo, i.classification AS classification,
                   i.tags AS tags
            FROM grac_practice.evidence_item i WHERE i.evidence_item_id = @evidence_item_id
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
           N'Active', @actor;

    COMMIT;

    SELECT CAST(1 AS BIT) AS Success, N'Evidence item saved.' AS Message;
END
GO

-- ---------------------------------------------------------------------
-- 4g. sp_evidence_center_status -- Retire / Restore / Delete.
--   Retire : kept and still shown where linked; cannot be newly linked.
--   Restore: back to Active.
--   Delete : only with no active link (plan: "unlink and delete are
--            different actions"); soft -- status Deleted, bytes kept.
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE grac_practice.sp_evidence_center_status
    @organization_id    BIGINT,
    @evidence_item_id   BIGINT,
    @action             NVARCHAR(20),
    @caller_employee_id BIGINT        = NULL,
    @caller_is_admin    BIT           = 0,
    @actor              NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @organization_id IS NULL OR @evidence_item_id IS NULL
        THROW 52781, 'Organization and evidence item are both required.', 1;
    SET @action = LTRIM(RTRIM(ISNULL(@action, N'')));
    IF @action NOT IN (N'Retire', N'Restore', N'Delete')
        THROW 52793, 'The action must be Retire, Restore or Delete.', 1;

    DECLARE @status NVARCHAR(30), @editable BIT = 0;
    SELECT @status   = i.status,
           @editable = CASE WHEN ed.is_editable = 1 THEN 1 ELSE 0 END
    FROM   grac_practice.evidence_item i
    OUTER  APPLY grac_practice.fn_pm_evidence_item_editable(
               i.owner_employee_id, i.created_by_employee_id,
               i.classification, @caller_employee_id, @caller_is_admin) ed
    WHERE  i.evidence_item_id = @evidence_item_id
      AND  i.organization_id  = @organization_id
      AND  i.status <> N'Deleted';

    IF @status IS NULL
        THROW 52784, 'That evidence item was not found in this organization.', 1;
    IF @editable = 0
        THROW 52785, 'Only the owner, the uploader or an organization admin can change this evidence item.', 1;

    DECLARE @new_status NVARCHAR(30) =
        CASE @action WHEN N'Retire' THEN N'Retired' WHEN N'Restore' THEN N'Active' ELSE N'Deleted' END;

    IF @action = N'Retire'  AND @status <> N'Active'
        THROW 52794, 'Only an active evidence item can be retired.', 1;
    IF @action = N'Restore' AND @status <> N'Retired'
        THROW 52795, 'Only a retired evidence item can be restored.', 1;
    IF @action = N'Delete'
       AND EXISTS (SELECT 1 FROM grac_practice.evidence_link l
                    WHERE l.evidence_item_id = @evidence_item_id AND l.status = N'Active')
        THROW 52796, 'This evidence is still linked. Remove it from every place that uses it first, or retire it instead.', 1;

    SET @actor = ISNULL(NULLIF(LTRIM(RTRIM(@actor)), N''), N'system');

    BEGIN TRAN;

    UPDATE grac_practice.evidence_item
       SET status = @new_status, updated_by = @actor, updated_dt = SYSUTCDATETIME()
     WHERE evidence_item_id = @evidence_item_id;

    INSERT grac_practice.practice_audit_trace(entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    SELECT N'evidence-item', @evidence_item_id, UPPER(@action),
           (SELECT @status AS status FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
           (SELECT @new_status AS status FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
           N'Active', @actor;

    COMMIT;

    SELECT CAST(1 AS BIT) AS Success,
           CASE @action WHEN N'Retire'  THEN N'Evidence item retired.'
                        WHEN N'Restore' THEN N'Evidence item restored.'
                        ELSE N'Evidence item deleted.' END AS Message;
END
GO

-- ---------------------------------------------------------------------
-- 4h. sp_evidence_center_lookups -- the screen's drop-downs.
--   Result 1: active evidence types.  Result 2: active employees of the
--   organisation (owner picker / owner filter).
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE grac_practice.sp_evidence_center_lookups
    @organization_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    IF @organization_id IS NULL
        THROW 52780, 'Select an organization.', 1;

    SELECT t.evidence_type_id   AS EvidenceTypeId,
           t.evidence_type_name AS EvidenceType
    FROM   grac_practice.evidence_type_master t
    WHERE  t.is_active = 1
    ORDER  BY t.display_order, t.evidence_type_name;

    SELECT e.employee_id   AS EmployeeId,
           e.employee_name AS EmployeeName,
           e.employee_code AS EmployeeCode
    FROM   grac_practice.organization_employee e
    WHERE  e.organization_id = @organization_id
      AND  e.status = N'Active'
    ORDER  BY e.employee_name;
END
GO

-- =====================================================================
-- 5. Linking -- Operationalize one-time evidence (Phase 1)
-- =====================================================================

-- ---------------------------------------------------------------------
-- 5a. sp_evidence_link_candidates -- the "Select from Evidence Center"
--     picker for one evidence row: Active items the caller can see.
--     Linkable = 0 for an expired item (valid to before today) and for
--     one already linked to this row; Reason says why.
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE grac_practice.sp_evidence_link_candidates
    @organization_id      BIGINT,
    @practice_instance_id BIGINT,
    @evidence_id          BIGINT,
    @caller_employee_id   BIGINT        = NULL,
    @caller_is_admin      BIT           = 0,
    @search               NVARCHAR(200) = NULL,
    @evidence_type_id     INT           = NULL,
    @page_number          INT           = 1,
    @page_size            INT           = 10
AS
BEGIN
    SET NOCOUNT ON;

    IF @organization_id IS NULL OR @practice_instance_id IS NULL OR @evidence_id IS NULL
        THROW 52850, 'Organization, practice instance and evidence row are all required.', 1;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.practice_instance_evidence e
                    WHERE e.evidence_id = @evidence_id
                      AND e.practice_instance_id = @practice_instance_id
                      AND e.organization_id = @organization_id
                      AND e.status = N'Active')
        THROW 52851, 'That evidence row was not found on this practice instance.', 1;

    SET @page_number = CASE WHEN ISNULL(@page_number, 0) < 1 THEN 1 ELSE @page_number END;
    SET @page_size   = CASE WHEN ISNULL(@page_size, 0) < 1 THEN 10 WHEN @page_size > 100 THEN 100 ELSE @page_size END;

    DECLARE @today DATE = CONVERT(DATE, SYSUTCDATETIME());
    DECLARE @s NVARCHAR(200) = NULLIF(LTRIM(RTRIM(@search)), N'');

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
           CAST(CASE WHEN al.linked = 1 THEN 1 ELSE 0 END AS BIT) AS AlreadyLinked,
           CAST(CASE WHEN al.linked = 1 OR (i.valid_to IS NOT NULL AND i.valid_to < @today)
                     THEN 0 ELSE 1 END AS BIT) AS Linkable,
           CASE WHEN al.linked = 1 THEN N'Already attached to this evidence.'
                WHEN i.valid_to IS NOT NULL AND i.valid_to < @today THEN N'Expired - upload a new version in the Evidence Center first.'
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
                    AND l2.target_type = N'InstanceEvidence' AND l2.target_id = @evidence_id) al
    WHERE  i.organization_id = @organization_id
      AND  i.status = N'Active'
      AND  (@evidence_type_id IS NULL OR i.evidence_type_id = @evidence_type_id)
      AND  (@s IS NULL
            OR i.evidence_title LIKE N'%' + @s + N'%'
            OR i.tags           LIKE N'%' + @s + N'%'
            OR f.file_name      LIKE N'%' + @s + N'%')
    ORDER  BY CASE WHEN al.linked = 1 THEN 1 ELSE 0 END, i.evidence_title, i.evidence_item_id
    OFFSET (@page_number - 1) * @page_size ROWS FETCH NEXT @page_size ROWS ONLY;
END
GO

-- ---------------------------------------------------------------------
-- 5b. sp_evidence_link_add -- link an existing item to a one-time
--     evidence row, pinned to its current version.
--     Result: EvidenceAttachmentId (= the link id), EvidenceItemId,
--             VersionNo, Message.
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE grac_practice.sp_evidence_link_add
    @organization_id      BIGINT,
    @practice_instance_id BIGINT,
    @evidence_id          BIGINT,
    @evidence_item_id     BIGINT,
    @link_note            NVARCHAR(1000) = NULL,
    @caller_employee_id   BIGINT         = NULL,
    @caller_is_admin      BIT            = 0,
    @actor                NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @organization_id IS NULL OR @practice_instance_id IS NULL OR @evidence_id IS NULL OR @evidence_item_id IS NULL
        THROW 52852, 'Organization, practice instance, evidence row and evidence item are all required.', 1;

    DECLARE @cadence NVARCHAR(30), @row_found BIT = 0;
    SELECT @row_found = 1, @cadence = c.EvidenceCadence
    FROM   grac_practice.practice_instance_evidence e
    LEFT   JOIN grac_practice.vw_pm_instance_evidence_cadence c ON c.evidence_id = e.evidence_id
    WHERE  e.evidence_id          = @evidence_id
      AND  e.practice_instance_id = @practice_instance_id
      AND  e.organization_id      = @organization_id
      AND  e.status = N'Active';

    IF @row_found = 0
        THROW 52851, 'That evidence row was not found on this practice instance.', 1;
    IF ISNULL(@cadence, N'Recurring') <> N'OneTime'
        THROW 52764, 'Only one-time evidence is attached on Operationalize. Recurring evidence is attached to each scheduled task when it is completed.', 1;

    IF @caller_employee_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee oe
                        WHERE oe.employee_id = @caller_employee_id
                          AND oe.organization_id = @organization_id)
        SET @caller_employee_id = NULL;

    DECLARE @status NVARCHAR(30), @visible BIT = 0, @valid_to DATE, @title NVARCHAR(300);
    SELECT @status = i.status, @valid_to = i.valid_to, @title = i.evidence_title,
           @visible = CASE WHEN v.is_visible = 1 THEN 1 ELSE 0 END
    FROM   grac_practice.evidence_item i
    OUTER  APPLY grac_practice.fn_pm_evidence_item_visible(
               i.evidence_item_id, i.owner_employee_id, i.created_by_employee_id,
               i.classification, @caller_employee_id, @caller_is_admin) v
    WHERE  i.evidence_item_id = @evidence_item_id
      AND  i.organization_id  = @organization_id
      AND  i.status <> N'Deleted';

    -- Not visible reads exactly like not found: nothing is revealed.
    IF @status IS NULL OR @visible = 0
        THROW 52784, 'That evidence item was not found in this organization.', 1;
    IF @status <> N'Active'
        THROW 52853, 'This evidence item is retired and cannot be linked.', 1;
    IF @valid_to IS NOT NULL AND @valid_to < CONVERT(DATE, SYSUTCDATETIME())
        THROW 52854, 'This evidence has expired. Upload a new version in the Evidence Center, or choose another item.', 1;
    IF EXISTS (SELECT 1 FROM grac_practice.evidence_link l
                WHERE l.target_type = N'InstanceEvidence' AND l.target_id = @evidence_id
                  AND l.evidence_item_id = @evidence_item_id AND l.status = N'Active')
        THROW 52855, 'This evidence item is already attached to this evidence.', 1;

    DECLARE @file_id BIGINT, @version_no INT;
    SELECT @file_id = f.evidence_file_id, @version_no = f.version_no
    FROM   grac_practice.evidence_item_file f
    WHERE  f.evidence_item_id = @evidence_item_id AND f.is_current = 1;
    IF @file_id IS NULL
        THROW 52856, 'This evidence item has no file.', 1;

    SET @actor = ISNULL(NULLIF(LTRIM(RTRIM(@actor)), N''), N'system');
    DECLARE @link_id BIGINT;

    BEGIN TRAN;

    INSERT grac_practice.evidence_link
        (organization_id, evidence_item_id, evidence_file_id, target_type, target_id,
         practice_instance_id, link_note, status, linked_by_employee_id, linked_by, linked_dt)
    VALUES
        (@organization_id, @evidence_item_id, @file_id, N'InstanceEvidence', @evidence_id,
         @practice_instance_id, NULLIF(LTRIM(RTRIM(@link_note)), N''), N'Active',
         @caller_employee_id, @actor, SYSUTCDATETIME());
    SET @link_id = SCOPE_IDENTITY();

    INSERT grac_practice.practice_audit_trace(entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    SELECT N'evidence-link', @link_id, N'CREATE', NULL,
           (SELECT @evidence_item_id AS evidenceItemId, @version_no AS versionNo,
                   @practice_instance_id AS practiceInstanceId, @evidence_id AS evidenceId
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
           N'Active', @actor;

    COMMIT;

    SELECT @link_id AS EvidenceAttachmentId, @evidence_item_id AS EvidenceItemId,
           @version_no AS VersionNo,
           N'Linked "' + @title + N'" (version ' + CAST(@version_no AS NVARCHAR(10)) + N').' AS Message;
END
GO

-- ---------------------------------------------------------------------
-- 5c. sp_evidence_link_refresh -- move a link to the item's latest
--     version ("A newer version exists - update?"). Scoped to the
--     instance the caller opened.
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE grac_practice.sp_evidence_link_refresh
    @organization_id      BIGINT,
    @practice_instance_id BIGINT,
    @evidence_link_id     BIGINT,
    @actor                NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @organization_id IS NULL OR @practice_instance_id IS NULL OR @evidence_link_id IS NULL
        THROW 52857, 'Organization, practice instance and attachment are all required.', 1;

    DECLARE @item_id BIGINT, @old_file BIGINT, @old_version INT, @new_file BIGINT, @new_version INT;
    SELECT @item_id = l.evidence_item_id, @old_file = l.evidence_file_id, @old_version = fo.version_no
    FROM   grac_practice.evidence_link l
    JOIN   grac_practice.evidence_item_file fo ON fo.evidence_file_id = l.evidence_file_id
    WHERE  l.evidence_link_id     = @evidence_link_id
      AND  l.practice_instance_id = @practice_instance_id
      AND  l.organization_id      = @organization_id
      AND  l.status = N'Active';

    IF @item_id IS NULL
        THROW 52858, 'That attachment was not found on this practice instance.', 1;

    SELECT @new_file = f.evidence_file_id, @new_version = f.version_no
    FROM   grac_practice.evidence_item_file f
    WHERE  f.evidence_item_id = @item_id AND f.is_current = 1;

    IF @new_file IS NULL OR @new_file = @old_file
    BEGIN
        SELECT CAST(1 AS BIT) AS Success, N'This attachment already shows the latest version.' AS Message;
        RETURN;
    END

    SET @actor = ISNULL(NULLIF(LTRIM(RTRIM(@actor)), N''), N'system');

    BEGIN TRAN;

    UPDATE grac_practice.evidence_link
       SET evidence_file_id = @new_file
     WHERE evidence_link_id = @evidence_link_id;

    INSERT grac_practice.practice_audit_trace(entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    SELECT N'evidence-link', @evidence_link_id, N'REFRESH',
           (SELECT @old_version AS versionNo FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
           (SELECT @new_version AS versionNo FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
           N'Active', @actor;

    COMMIT;

    SELECT CAST(1 AS BIT) AS Success,
           N'Updated to version ' + CAST(@new_version AS NVARCHAR(10)) + N'.' AS Message;
END
GO

-- =====================================================================
-- 6. The 473 attachment procedures, re-issued over links. Same names,
--    same parameters (one optional addition), same result columns plus
--    the Evidence Center ones -- the Operationalize page and the API keep
--    working; EvidenceAttachmentId is now evidence_link_id.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 6a. sp_resolve_evidence_attachment_add -- "Upload new".
--   The file becomes a new Evidence Center item (title = file name, the
--   evidence row's type, owner = uploader, Internal) linked here. When the
--   uploader can already see an Active, unexpired item whose current
--   version is the identical file, that item is linked instead of storing
--   the file again (Reused = 1).
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

-- ---------------------------------------------------------------------
-- 6b. sp_resolve_evidence_attachment_list -- metadata only (no bytes).
--     473 columns (file = the PINNED version) + Evidence Center columns.
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE grac_practice.sp_resolve_evidence_attachment_list
    @practice_instance_id BIGINT,
    @organization_id      BIGINT = NULL   -- NULL = no check (see _add)
AS
BEGIN
    SET NOCOUNT ON;

    IF @practice_instance_id IS NULL
        THROW 52765, 'sp_resolve_evidence_attachment_list: practice_instance_id is required.', 1;

    DECLARE @today DATE = CONVERT(DATE, SYSUTCDATETIME());

    SELECT l.evidence_link_id        AS EvidenceAttachmentId,
           l.target_id               AS EvidenceId,
           f.file_name               AS FileName,
           f.content_type            AS ContentType,
           f.file_size_bytes         AS FileSizeBytes,
           l.link_note               AS AttachmentDescription,
           f.uploaded_by_employee_id AS UploadedByEmployeeId,
           COALESCE(up.employee_name, f.uploaded_by) AS UploadedByName,
           f.uploaded_dt             AS UploadedDt,
           -- 476
           l.evidence_item_id        AS EvidenceItemId,
           i.evidence_title          AS EvidenceTitle,
           i.status                  AS EvidenceItemStatus,
           f.version_no              AS VersionNo,
           cur.version_no            AS CurrentVersionNo,
           CAST(CASE WHEN cur.evidence_file_id IS NOT NULL AND cur.evidence_file_id <> f.evidence_file_id
                     THEN 1 ELSE 0 END AS BIT) AS NewerVersionAvailable,
           i.valid_to                AS ValidTo,
           CASE WHEN i.valid_to IS NULL THEN N'NoExpiry'
                WHEN i.valid_to < @today THEN N'Expired'
                WHEN i.valid_to <= DATEADD(DAY, 30, @today) THEN N'Expiring'
                ELSE N'Valid' END    AS ValidityState,
           COALESCE(lb.employee_name, l.linked_by) AS LinkedByName,
           l.linked_dt               AS LinkedDt
    FROM   grac_practice.evidence_link l
    JOIN   grac_practice.evidence_item_file f ON f.evidence_file_id = l.evidence_file_id
    JOIN   grac_practice.evidence_item i      ON i.evidence_item_id = l.evidence_item_id
    LEFT   JOIN grac_practice.evidence_item_file cur
           ON cur.evidence_item_id = l.evidence_item_id AND cur.is_current = 1
    LEFT   JOIN grac_practice.organization_employee up ON up.employee_id = f.uploaded_by_employee_id
    LEFT   JOIN grac_practice.organization_employee lb ON lb.employee_id = l.linked_by_employee_id
    WHERE  l.practice_instance_id = @practice_instance_id
      AND  l.target_type = N'InstanceEvidence'
      AND  l.status = N'Active'
      AND  (@organization_id IS NULL OR l.organization_id = @organization_id)
    ORDER  BY l.target_id, l.linked_dt DESC, l.evidence_link_id DESC;
END
GO

-- ---------------------------------------------------------------------
-- 6c. sp_resolve_evidence_attachment_get -- the PINNED version of one
--     link, for download. Scoped to the instance.
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE grac_practice.sp_resolve_evidence_attachment_get
    @practice_instance_id   BIGINT,
    @evidence_attachment_id BIGINT,
    @organization_id        BIGINT = NULL   -- NULL = no check (see _add)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT l.evidence_link_id  AS EvidenceAttachmentId,
           l.target_id         AS EvidenceId,
           f.file_name         AS FileName,
           f.content_type      AS ContentType,
           f.file_size_bytes   AS FileSizeBytes,
           f.file_data         AS FileData
    FROM   grac_practice.evidence_link l
    JOIN   grac_practice.evidence_item_file f ON f.evidence_file_id = l.evidence_file_id
    WHERE  l.evidence_link_id     = @evidence_attachment_id
      AND  l.practice_instance_id = @practice_instance_id
      AND  l.target_type = N'InstanceEvidence'
      AND  l.status = N'Active'
      AND  (@organization_id IS NULL OR l.organization_id = @organization_id);
END
GO

-- ---------------------------------------------------------------------
-- 6d. sp_resolve_evidence_attachment_remove -- UNLINK, audited. The item
--     and its files stay in the Evidence Center.
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

    DECLARE @evidence_id BIGINT, @item_id BIGINT, @version_no INT;
    SELECT @evidence_id = l.target_id, @item_id = l.evidence_item_id, @version_no = f.version_no
    FROM   grac_practice.evidence_link l
    JOIN   grac_practice.evidence_item_file f ON f.evidence_file_id = l.evidence_file_id
    WHERE  l.evidence_link_id     = @evidence_attachment_id
      AND  l.practice_instance_id = @practice_instance_id
      AND  l.target_type = N'InstanceEvidence'
      AND  l.status = N'Active'
      AND  (@organization_id IS NULL OR l.organization_id = @organization_id);

    IF @evidence_id IS NULL
        THROW 52767, 'sp_resolve_evidence_attachment_remove: that attachment was not found on this practice instance.', 1;

    SET @actor = ISNULL(NULLIF(LTRIM(RTRIM(@actor)), N''), N'system');

    BEGIN TRAN;

    UPDATE grac_practice.evidence_link
       SET status     = N'Removed',
           removed_by = @actor,
           removed_dt = SYSUTCDATETIME()
     WHERE evidence_link_id = @evidence_attachment_id;

    INSERT grac_practice.practice_audit_trace(entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    SELECT N'evidence-link', @evidence_attachment_id, N'REMOVE',
           (SELECT @practice_instance_id AS practiceInstanceId, @evidence_id AS evidenceId,
                   @item_id AS evidenceItemId, @version_no AS versionNo, N'Active' AS status
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
           (SELECT N'Removed' AS status FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
           N'Active', @actor;

    COMMIT;

    SELECT CAST(1 AS BIT) AS Success,
           N'Removed from this evidence. The file stays in the Evidence Center.' AS Message;
END
GO

-- =====================================================================
-- 7. sp_resolve_evidence_list -- AttachmentCount counts links.
-- =====================================================================
-- ---------------------------------------------------------------------
-- 7. sp_resolve_evidence_list (473 body; only AttachmentCount changes)
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
        -- 476: files are Evidence Center links now.
        (SELECT COUNT(*) FROM grac_practice.evidence_link ea
          WHERE ea.target_type = N'InstanceEvidence'
            AND ea.target_id = e.evidence_id AND ea.status = N'Active') AS AttachmentCount
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

-- =====================================================================
-- 8. Menu: Policies & Documents -> Evidence Center
-- =====================================================================
DECLARE @documents_id BIGINT = (SELECT menu_id FROM grac_practice.menu_master WHERE menu_key = N'nav-documents');

MERGE grac_practice.menu_master AS target
USING (VALUES
    (N'evidence-center', N'Evidence Center', N'Practice/Index/evidence-center', 15, N'box-archive')
) AS src(menu_key, menu_name, menu_url, display_order, icon_class)
ON target.menu_key = src.menu_key
WHEN MATCHED THEN UPDATE SET
    menu_name = src.menu_name, menu_url = src.menu_url,
    parent_menu_id = @documents_id, display_order = src.display_order,
    icon_class = src.icon_class, module_type = N'Policies & Documents',
    status = N'Active', updated_by = 'seed-476', updated_dt = SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT
    (menu_key, menu_name, menu_url, parent_menu_id, display_order, icon_class, module_type, status, entered_by)
VALUES
    (src.menu_key, src.menu_name, src.menu_url, @documents_id, src.display_order,
     src.icon_class, N'Policies & Documents', N'Active', 'seed-476');
PRINT '476: evidence-center menu row upserted = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

-- Every active role in every active organisation, as 458 did. The
-- procedures still decide WHICH items a user sees (visibility rule) and
-- may change (owner / uploader / admin); narrow the menu in Role Menu
-- Permissions if wanted.
DECLARE @active_rs INT = (
    SELECT TOP 1 record_status_id FROM grac_practice.record_status_master
     WHERE status_code = N'Active' OR status_name = N'Active' ORDER BY record_status_id);
IF @active_rs IS NULL SET @active_rs = 1;

INSERT grac_practice.organization_role_menu_permission
    (role_id, menu_id, can_view, can_add, can_edit, can_delete, can_approve,
     status, record_status_id, entered_by, entered_dt)
SELECT r.role_id, m.menu_id, 1, 1, 1, 1, 1,
       N'Active', @active_rs, N'seed-476', SYSUTCDATETIME()
FROM   grac_practice.organization_role r
JOIN   grac_practice.organization o ON o.organization_id = r.organization_id
JOIN   grac_practice.menu_master m ON m.menu_key = N'evidence-center'
WHERE  o.status = N'Active' AND r.status = N'Active'
  AND NOT EXISTS (
        SELECT 1 FROM grac_practice.organization_role_menu_permission p
        WHERE p.role_id = r.role_id AND p.menu_id = m.menu_id);
PRINT '476: evidence-center permission rows inserted = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

-- =====================================================================
-- 9. Verification
-- =====================================================================
SELECT '476 tables' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.evidence_item','U')      IS NOT NULL
             AND OBJECT_ID('grac_practice.evidence_item_file','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.evidence_link','U')      IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result_
UNION ALL
SELECT '476 procedures',
       CASE WHEN OBJECT_ID('grac_practice.sp_evidence_center_list','P')      IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_evidence_center_get','P')       IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_evidence_center_file_get','P')  IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_evidence_center_upload','P')    IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_evidence_center_save','P')      IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_evidence_center_status','P')    IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_evidence_center_lookups','P')   IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_evidence_item_store','P')       IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_evidence_link_candidates','P')  IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_evidence_link_add','P')         IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_evidence_link_refresh','P')     IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '476 attachment procedures read links',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_resolve_evidence_attachment_list')) LIKE '%evidence_link%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_resolve_evidence_attachment_add'))  LIKE '%sp_evidence_item_store%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_resolve_evidence_list'))            LIKE '%evidence_link%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '476 every active 473 attachment migrated',
       CASE WHEN NOT EXISTS (
              SELECT 1 FROM grac_practice.practice_instance_evidence_attachment a
              WHERE a.status = N'Active'
                AND NOT EXISTS (SELECT 1 FROM grac_practice.evidence_link l
                                 WHERE l.legacy_attachment_id = a.evidence_attachment_id))
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '476 evidence-center sits under Policies & Documents',
       CASE WHEN EXISTS (
              SELECT 1 FROM grac_practice.menu_master m
              JOIN grac_practice.menu_master p ON p.menu_id = m.parent_menu_id
              WHERE m.menu_key = N'evidence-center' AND p.menu_key = N'nav-documents'
                AND m.status = N'Active' AND m.menu_url = N'Practice/Index/evidence-center')
            THEN 'PASS' ELSE 'FAIL' END;
GO

SELECT i.organization_id,
       Items       = COUNT(DISTINCT i.evidence_item_id),
       Files       = (SELECT COUNT(*) FROM grac_practice.evidence_item_file f WHERE f.organization_id = i.organization_id),
       ActiveLinks = (SELECT COUNT(*) FROM grac_practice.evidence_link l
                       WHERE l.organization_id = i.organization_id AND l.status = N'Active')
FROM   grac_practice.evidence_item i
GROUP  BY i.organization_id
ORDER  BY i.organization_id;
GO

PRINT '476 complete.';
GO
