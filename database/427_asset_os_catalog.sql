-- =====================================================================
-- 427  Technology catalogue: operating-system products, releases and
--      compatibility (Asset & Contract Management, Phase 3 increment 3)
--
-- REQUEST
-- -------
--   BRD v1.7 4.5 (Operating System Catalog and Compatibility), 4.8
--   ("only approved compatibility mappings can drive automated
--   recommendations", "lifecycle dates cannot be overwritten without
--   reason and history", "end-of-support dates cannot precede release
--   dates") and section 15 (OperatingSystemProduct, OperatingSystemRelease,
--   OSModelCompatibility). Same shape as 426 (firmware). Plan in
--   docs/asset-contract-management.md.
--
-- WHAT THIS DOES
-- --------------
--   1. asset_os_product -- publisher (a make: 4.2 "OS publishers"), family
--      and product (e.g. Microsoft / Windows / Windows Server).
--   2. asset_os_release -- 4.5 field groups: identity (edition, version,
--      build, architecture), lifecycle (release, mainstream support end,
--      extended support end, security-update end, end of life), servicing
--      (channel, feature version, patch level, latest approved build,
--      minimum compliant build), governance (source, verification,
--      approved baseline flag, exception note, replacement path -- a
--      release and / or text).
--   3. Release status = the BRD 4.5 list on the state-machine framework
--      (entity OsRelease): Draft -> Approved -> Supported / Extended
--      Support / Approaching EOS / EOS / Unsupported, forward only except
--      Approaching EOS -> Extended Support (an extension; reason
--      required). The BRD list has no Withdrawn status, so none is added.
--      Approval needs APPROVE, a source reference and an approver other
--      than the last draft editor (as 426, decision D11). After approval
--      the identity is locked; overwriting a lifecycle date needs a
--      reason, recorded in technology_lifecycle_event (entity OS).
--   4. asset_os_compatibility -- one explicit row per OS release + asset
--      type (+ optional make, model, processor / architecture, minimum
--      firmware release as the firmware prerequisite) with exclusions,
--      evidence and reviewer. The BRD gives OS compatibility no status
--      list or effective dates, so a row states "supported, with these
--      exclusions". Rows are Draft until approved (evidence required,
--      approver other than the last editor); editing an approved row
--      returns it to Draft; rows are deactivated, never deleted.
--   5. sp_asset_model_os_list -- approved, active compatibility for a
--      model (model / make / asset-type match) with whether the
--      architecture matches the model's.
--   6. Scope as 425 / 426 (organization_id NULL = shared catalogue).
--
-- DUPLICATE RULES
--   Product: publisher + family + name unique among visible products.
--   Release: product + edition + version + build + architecture unique.
--   Compatibility: release + asset type + make + model + architecture
--   unique among active visible rows.
--
-- NOT DONE HERE: installed OS per asset (4.6 AssetOSInstallation -- needs
--   the Asset Register, Phase 4); OS-based posture and campaigns.
--
-- ERROR NUMBERS: 54910-54939
--   54910 organization not found          54911 product not found
--   54912 product name required           54913 product already exists
--   54914 shared-catalogue scope mismatch 54915 changed by someone else
--   54916 publisher (make) not usable     54917 release not found
--   54918 version required                54919 release already exists
--   54920 date sequence                   54921 reason required (milestone overwrite)
--   54922 identity locked                 54923 not ready to approve
--   54924 segregation of duties           54925 reason required (status move)
--   54926 compatibility row not found     54927 asset type not valid
--   54928 make / model not consistent     54929 firmware prerequisite not valid
--   54930 compatibility duplicate         54931 compatibility not ready to approve
--   54932 replacement release not valid
--
-- ALSO EDITED: API (AssetConfig service / controller / models), Web
--   asset-tech-catalog partial + script (Operating Systems tab; OS on the
--   model). No new menu row; the Web proxy rules of 425 / 426 apply.
-- DEPENDS ON: 425, 426.
-- Rollback: 427_asset_os_catalog_rollback.sql
-- Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.asset_model','U') IS NULL
   OR OBJECT_ID('grac_practice.asset_firmware_release','U') IS NULL
   OR OBJECT_ID('grac_practice.technology_lifecycle_event','U') IS NULL
BEGIN
    RAISERROR('ABORT (427): run 425 and 426 first.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. Tables
-- =====================================================================
IF OBJECT_ID('grac_practice.asset_os_product','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_os_product (
        product_id        INT            IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_asset_os_product PRIMARY KEY,
        organization_id   BIGINT         NULL
            CONSTRAINT fk_pm_asset_os_product_org REFERENCES grac_practice.organization(organization_id),
        publisher_make_id INT            NOT NULL
            CONSTRAINT fk_pm_asset_os_product_make REFERENCES grac_practice.asset_make(make_id),
        product_code      NVARCHAR(100)  NOT NULL CONSTRAINT uq_pm_asset_os_product_code UNIQUE,
        family            NVARCHAR(120)  NULL,
        product_name      NVARCHAR(200)  NOT NULL,
        description       NVARCHAR(1000) NULL,
        status            NVARCHAR(30)   NOT NULL CONSTRAINT df_pm_asset_os_product_status DEFAULT N'Active'
            CONSTRAINT ck_pm_asset_os_product_status CHECK (status IN (N'Active', N'Inactive')),
        entered_by        NVARCHAR(100)  NOT NULL CONSTRAINT df_pm_asset_os_product_eby DEFAULT N'system',
        entered_dt        DATETIME2      NOT NULL CONSTRAINT df_pm_asset_os_product_edt DEFAULT SYSUTCDATETIME(),
        updated_by        NVARCHAR(100)  NULL,
        updated_dt        DATETIME2      NULL,
        record_version    ROWVERSION     NOT NULL
    );
    PRINT '427: asset_os_product created.';
END
GO

IF OBJECT_ID('grac_practice.asset_os_release','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_os_release (
        release_id                 BIGINT         IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_asset_os_release PRIMARY KEY,
        organization_id            BIGINT         NULL
            CONSTRAINT fk_pm_asset_os_release_org REFERENCES grac_practice.organization(organization_id),
        product_id                 INT            NOT NULL
            CONSTRAINT fk_pm_asset_os_release_product REFERENCES grac_practice.asset_os_product(product_id),
        release_code               NVARCHAR(140)  NOT NULL CONSTRAINT uq_pm_asset_os_release_code UNIQUE,
        edition                    NVARCHAR(100)  NULL,
        version                    NVARCHAR(100)  NOT NULL,
        build                      NVARCHAR(100)  NULL,
        architecture               NVARCHAR(60)   NULL,
        release_date               DATE           NULL,
        mainstream_support_end_date DATE          NULL,
        extended_support_end_date  DATE           NULL,
        security_update_end_date   DATE           NULL,
        end_of_life_date           DATE           NULL,
        servicing_channel          NVARCHAR(100)  NULL,
        feature_version            NVARCHAR(100)  NULL,
        patch_level                NVARCHAR(100)  NULL,
        latest_approved_build      NVARCHAR(100)  NULL,
        minimum_compliant_build    NVARCHAR(100)  NULL,
        source_reference           NVARCHAR(500)  NULL,
        verified_date              DATE           NULL,
        verified_by                NVARCHAR(200)  NULL,
        is_approved_baseline       BIT            NOT NULL CONSTRAINT df_pm_asset_os_release_baseline DEFAULT 0,
        exception_note             NVARCHAR(1000) NULL,
        replacement_release_id     BIGINT         NULL
            CONSTRAINT fk_pm_asset_os_release_replacement REFERENCES grac_practice.asset_os_release(release_id),
        replacement_path           NVARCHAR(500)  NULL,
        current_status_id          INT            NOT NULL
            CONSTRAINT fk_pm_asset_os_release_status REFERENCES grac_practice.entity_status_master(entity_status_id),
        draft_edited_by            NVARCHAR(100)  NULL,
        approved_by                NVARCHAR(100)  NULL,
        approved_dt                DATETIME2      NULL,
        entered_by                 NVARCHAR(100)  NOT NULL CONSTRAINT df_pm_asset_os_release_eby DEFAULT N'system',
        entered_dt                 DATETIME2      NOT NULL CONSTRAINT df_pm_asset_os_release_edt DEFAULT SYSUTCDATETIME(),
        updated_by                 NVARCHAR(100)  NULL,
        updated_dt                 DATETIME2      NULL,
        record_version             ROWVERSION     NOT NULL,
        CONSTRAINT ck_pm_asset_os_release_dates CHECK (
            release_date IS NULL OR (
                (mainstream_support_end_date IS NULL OR mainstream_support_end_date >= release_date) AND
                (extended_support_end_date   IS NULL OR extended_support_end_date   >= release_date) AND
                (security_update_end_date    IS NULL OR security_update_end_date    >= release_date) AND
                (end_of_life_date            IS NULL OR end_of_life_date            >= release_date))),
        CONSTRAINT ck_pm_asset_os_release_not_self CHECK (replacement_release_id IS NULL OR replacement_release_id <> release_id)
    );
    CREATE INDEX ix_pm_asset_os_release_product ON grac_practice.asset_os_release(product_id);
    PRINT '427: asset_os_release created.';
END
GO

IF OBJECT_ID('grac_practice.asset_os_compatibility','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_os_compatibility (
        compat_id              BIGINT         IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_asset_os_compat PRIMARY KEY,
        organization_id        BIGINT         NULL
            CONSTRAINT fk_pm_asset_os_compat_org REFERENCES grac_practice.organization(organization_id),
        release_id             BIGINT         NOT NULL
            CONSTRAINT fk_pm_asset_os_compat_release REFERENCES grac_practice.asset_os_release(release_id),
        asset_type_id          INT            NOT NULL
            CONSTRAINT fk_pm_asset_os_compat_type REFERENCES grac_practice.dependency_asset_type_master(asset_type_id),
        make_id                INT            NULL
            CONSTRAINT fk_pm_asset_os_compat_make REFERENCES grac_practice.asset_make(make_id),
        model_id               BIGINT         NULL
            CONSTRAINT fk_pm_asset_os_compat_model REFERENCES grac_practice.asset_model(model_id),
        processor_architecture NVARCHAR(60)   NULL,
        min_firmware_release_id BIGINT        NULL
            CONSTRAINT fk_pm_asset_os_compat_firmware REFERENCES grac_practice.asset_firmware_release(release_id),
        firmware_prerequisite  NVARCHAR(500)  NULL,
        exclusions             NVARCHAR(1000) NULL,
        evidence               NVARCHAR(1000) NULL,
        reviewer               NVARCHAR(200)  NULL,
        approval_status        NVARCHAR(20)   NOT NULL CONSTRAINT df_pm_asset_os_compat_approval DEFAULT N'DRAFT'
            CONSTRAINT ck_pm_asset_os_compat_approval CHECK (approval_status IN (N'DRAFT', N'APPROVED')),
        edited_by              NVARCHAR(100)  NULL,
        approved_by            NVARCHAR(100)  NULL,
        approved_dt            DATETIME2      NULL,
        is_active              BIT            NOT NULL CONSTRAINT df_pm_asset_os_compat_active DEFAULT 1,
        entered_by             NVARCHAR(100)  NOT NULL CONSTRAINT df_pm_asset_os_compat_eby DEFAULT N'system',
        entered_dt             DATETIME2      NOT NULL CONSTRAINT df_pm_asset_os_compat_edt DEFAULT SYSUTCDATETIME(),
        updated_by             NVARCHAR(100)  NULL,
        updated_dt             DATETIME2      NULL,
        record_version         ROWVERSION     NOT NULL
    );
    CREATE INDEX ix_pm_asset_os_compat_release ON grac_practice.asset_os_compatibility(release_id);
    CREATE INDEX ix_pm_asset_os_compat_model   ON grac_practice.asset_os_compatibility(model_id, asset_type_id, make_id);
    PRINT '427: asset_os_compatibility created.';
END
GO

-- =====================================================================
-- 2. Release status (state-machine framework) -- the BRD 4.5 list
-- =====================================================================
MERGE grac_practice.entity_status_master AS t
USING (VALUES
    (N'OsRelease', N'DRAFT',            N'Draft',            10, 0, 1, N'Being prepared; not used for compatibility or recommendations.'),
    (N'OsRelease', N'APPROVED',         N'Approved',         20, 0, 0, N'Approved catalogue release.'),
    (N'OsRelease', N'SUPPORTED',        N'Supported',        30, 0, 0, N'In mainstream support.'),
    (N'OsRelease', N'EXTENDED_SUPPORT', N'Extended Support', 40, 0, 0, N'In extended support.'),
    (N'OsRelease', N'APPROACHING_EOS',  N'Approaching EOS',  50, 0, 0, N'End of support is near; plan the replacement.'),
    (N'OsRelease', N'EOS',              N'EOS',              60, 0, 0, N'End of support.'),
    (N'OsRelease', N'UNSUPPORTED',      N'Unsupported',      70, 1, 0, N'No longer supported.')
) AS s(entity_type, status_code, status_name, display_order, is_terminal, is_initial, description)
ON t.entity_type = s.entity_type AND t.status_code = s.status_code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (entity_type, status_code, status_name, display_order, is_terminal, is_initial, description, entered_by)
    VALUES (s.entity_type, s.status_code, s.status_name, s.display_order, s.is_terminal, s.is_initial, s.description, N'seed-427');
PRINT CONCAT('427: OsRelease statuses inserted: ', @@ROWCOUNT);
GO

MERGE grac_practice.entity_state_transition_rule AS t
USING (VALUES
    (CAST(NULL AS NVARCHAR(60)), N'DRAFT', 0, 0, N'Create a release.'),
    (N'DRAFT',            N'APPROVED',         0, 1, N'Approve the release.'),
    (N'APPROVED',         N'SUPPORTED',        0, 0, N'In mainstream support.'),
    (N'APPROVED',         N'EXTENDED_SUPPORT', 0, 0, N'In extended support.'),
    (N'APPROVED',         N'APPROACHING_EOS',  0, 0, N'End of support is near.'),
    (N'APPROVED',         N'EOS',              0, 0, N'End of support reached.'),
    (N'APPROVED',         N'UNSUPPORTED',      0, 0, N'No longer supported.'),
    (N'SUPPORTED',        N'EXTENDED_SUPPORT', 0, 0, N'Mainstream support ended.'),
    (N'SUPPORTED',        N'APPROACHING_EOS',  0, 0, N'End of support is near.'),
    (N'SUPPORTED',        N'EOS',              0, 0, N'End of support reached.'),
    (N'SUPPORTED',        N'UNSUPPORTED',      0, 0, N'No longer supported.'),
    (N'EXTENDED_SUPPORT', N'APPROACHING_EOS',  0, 0, N'End of support is near.'),
    (N'EXTENDED_SUPPORT', N'EOS',              0, 0, N'End of support reached.'),
    (N'EXTENDED_SUPPORT', N'UNSUPPORTED',      0, 0, N'No longer supported.'),
    (N'APPROACHING_EOS',  N'EXTENDED_SUPPORT', 1, 0, N'Support extended.'),
    (N'APPROACHING_EOS',  N'EOS',              0, 0, N'End of support reached.'),
    (N'APPROACHING_EOS',  N'UNSUPPORTED',      0, 0, N'No longer supported.'),
    (N'EOS',              N'UNSUPPORTED',      0, 0, N'No longer supported.')
) AS s(from_status_code, to_status_code, requires_reason, requires_approval, description)
ON t.entity_type = N'OsRelease'
   AND ISNULL(t.from_status_code, N'__NULL__') = ISNULL(s.from_status_code, N'__NULL__')
   AND t.to_status_code = s.to_status_code
   AND t.actor_role_code IS NULL
WHEN NOT MATCHED BY TARGET THEN
    INSERT (entity_type, from_status_code, to_status_code, actor_role_code, requires_reason, requires_approval, description, entered_by)
    VALUES (N'OsRelease', s.from_status_code, s.to_status_code, NULL, s.requires_reason, s.requires_approval, s.description, N'seed-427');
PRINT CONCAT('427: OsRelease transition rules inserted: ', @@ROWCOUNT);
GO

-- =====================================================================
-- 3. Readers
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_os_list
    @organization_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 54910, 'Organization not found.', 1;

    -- 1. Products
    SELECT p.product_id AS ProductId, CAST(CASE WHEN p.organization_id IS NULL THEN 1 ELSE 0 END AS BIT) AS IsShared,
           p.publisher_make_id AS PublisherMakeId, m.make_name AS PublisherName, p.product_code AS ProductCode,
           p.family AS Family, p.product_name AS ProductName, p.description AS Description, p.status AS Status,
           CONVERT(BIGINT, p.record_version) AS RecordVersion,
           (SELECT COUNT(*) FROM grac_practice.asset_os_release r
             WHERE r.product_id = p.product_id AND (r.organization_id IS NULL OR r.organization_id = @organization_id)) AS ReleaseCount
      FROM grac_practice.asset_os_product p
      JOIN grac_practice.asset_make m ON m.make_id = p.publisher_make_id
     WHERE p.organization_id IS NULL OR p.organization_id = @organization_id
     ORDER BY m.make_name, p.family, p.product_name;

    -- 2. Releases
    SELECT r.release_id AS ReleaseId, CAST(CASE WHEN r.organization_id IS NULL THEN 1 ELSE 0 END AS BIT) AS IsShared,
           r.product_id AS ProductId, p.product_name AS ProductName, p.family AS Family, m.make_name AS PublisherName,
           r.release_code AS ReleaseCode, r.edition AS Edition, r.version AS Version, r.build AS Build,
           r.architecture AS Architecture, r.release_date AS ReleaseDate,
           r.mainstream_support_end_date AS MainstreamSupportEndDate, r.extended_support_end_date AS ExtendedSupportEndDate,
           r.end_of_life_date AS EndOfLifeDate, r.is_approved_baseline AS IsApprovedBaseline,
           s.status_code AS StatusCode, s.status_name AS StatusName,
           (SELECT COUNT(*) FROM grac_practice.asset_os_compatibility c
             WHERE c.release_id = r.release_id AND c.is_active = 1
               AND (c.organization_id IS NULL OR c.organization_id = @organization_id)) AS CompatCount,
           (SELECT COUNT(*) FROM grac_practice.asset_os_compatibility c
             WHERE c.release_id = r.release_id AND c.is_active = 1 AND c.approval_status = N'APPROVED'
               AND (c.organization_id IS NULL OR c.organization_id = @organization_id)) AS ApprovedCompatCount
      FROM grac_practice.asset_os_release r
      JOIN grac_practice.asset_os_product p ON p.product_id = r.product_id
      JOIN grac_practice.asset_make m ON m.make_id = p.publisher_make_id
      JOIN grac_practice.entity_status_master s ON s.entity_status_id = r.current_status_id
     WHERE r.organization_id IS NULL OR r.organization_id = @organization_id
     ORDER BY m.make_name, p.product_name, r.version, r.build;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_asset_os_release_get
    @organization_id BIGINT,
    @release_id      BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.asset_os_release
                    WHERE release_id = @release_id AND (organization_id IS NULL OR organization_id = @organization_id))
        THROW 54917, 'Operating-system release not found.', 1;

    -- 1. The release
    SELECT r.release_id AS ReleaseId, CAST(CASE WHEN r.organization_id IS NULL THEN 1 ELSE 0 END AS BIT) AS IsShared,
           r.product_id AS ProductId, p.product_name AS ProductName, p.family AS Family, m.make_name AS PublisherName,
           r.release_code AS ReleaseCode, r.edition AS Edition, r.version AS Version, r.build AS Build,
           r.architecture AS Architecture, r.release_date AS ReleaseDate,
           r.mainstream_support_end_date AS MainstreamSupportEndDate, r.extended_support_end_date AS ExtendedSupportEndDate,
           r.security_update_end_date AS SecurityUpdateEndDate, r.end_of_life_date AS EndOfLifeDate,
           r.servicing_channel AS ServicingChannel, r.feature_version AS FeatureVersion, r.patch_level AS PatchLevel,
           r.latest_approved_build AS LatestApprovedBuild, r.minimum_compliant_build AS MinimumCompliantBuild,
           r.source_reference AS SourceReference, r.verified_date AS VerifiedDate, r.verified_by AS VerifiedBy,
           r.is_approved_baseline AS IsApprovedBaseline, r.exception_note AS ExceptionNote,
           r.replacement_release_id AS ReplacementReleaseId,
           CASE WHEN rr.release_id IS NULL THEN NULL ELSE CONCAT(rp.product_name, N' ', rr.version, N' ', rr.edition) END AS ReplacementReleaseName,
           r.replacement_path AS ReplacementPath, s.status_code AS StatusCode, s.status_name AS StatusName,
           r.draft_edited_by AS DraftEditedBy, r.approved_by AS ApprovedBy, r.approved_dt AS ApprovedDt,
           CONVERT(BIGINT, r.record_version) AS RecordVersion
      FROM grac_practice.asset_os_release r
      JOIN grac_practice.asset_os_product p ON p.product_id = r.product_id
      JOIN grac_practice.asset_make m ON m.make_id = p.publisher_make_id
      JOIN grac_practice.entity_status_master s ON s.entity_status_id = r.current_status_id
      LEFT JOIN grac_practice.asset_os_release rr ON rr.release_id = r.replacement_release_id
      LEFT JOIN grac_practice.asset_os_product rp ON rp.product_id = rr.product_id
     WHERE r.release_id = @release_id;

    -- 2. Compatibility rows visible to the organization
    SELECT c.compat_id AS CompatId, CAST(CASE WHEN c.organization_id IS NULL THEN 1 ELSE 0 END AS BIT) AS IsShared,
           c.asset_type_id AS AssetTypeId, t.asset_type_name AS AssetTypeName, c.make_id AS MakeId, mk.make_name AS MakeName,
           c.model_id AS ModelId, md.model_name AS ModelName, md.variant AS ModelVariant,
           c.processor_architecture AS ProcessorArchitecture, c.min_firmware_release_id AS MinFirmwareReleaseId,
           CASE WHEN fr.release_id IS NULL THEN NULL ELSE CONCAT(fp.product_name, N' ', fr.version) END AS MinFirmwareName, c.firmware_prerequisite AS FirmwarePrerequisite,
           c.exclusions AS Exclusions, c.evidence AS Evidence, c.reviewer AS Reviewer, c.approval_status AS ApprovalStatus,
           c.edited_by AS EditedBy, c.approved_by AS ApprovedBy, c.approved_dt AS ApprovedDt, c.is_active AS IsActive,
           CONVERT(BIGINT, c.record_version) AS RecordVersion
      FROM grac_practice.asset_os_compatibility c
      JOIN grac_practice.dependency_asset_type_master t ON t.asset_type_id = c.asset_type_id
      LEFT JOIN grac_practice.asset_make mk ON mk.make_id = c.make_id
      LEFT JOIN grac_practice.asset_model md ON md.model_id = c.model_id
      LEFT JOIN grac_practice.asset_firmware_release fr ON fr.release_id = c.min_firmware_release_id
      LEFT JOIN grac_practice.asset_firmware_product fp ON fp.product_id = fr.product_id
     WHERE c.release_id = @release_id AND (c.organization_id IS NULL OR c.organization_id = @organization_id)
     ORDER BY c.is_active DESC, t.asset_type_name, mk.make_name, md.model_name;

    -- 3. Lifecycle milestone history
    SELECT e.event_id AS EventId, e.milestone_code AS MilestoneCode, e.before_value AS BeforeValue,
           e.after_value AS AfterValue, e.source AS Source, e.reason AS Reason, e.entered_by AS EnteredBy, e.entered_dt AS EnteredDt
      FROM grac_practice.technology_lifecycle_event e
     WHERE e.entity_type = N'OS' AND e.entity_id = @release_id
     ORDER BY e.entered_dt DESC, e.event_id DESC;

    -- 4. Status history
    SELECT l.transition_log_id AS TransitionLogId, fs.status_name AS FromStatus, ts.status_name AS ToStatus,
           l.actor_employee_id AS ActorEmployeeId, emp.employee_name AS ActorName,
           l.reason_code AS ReasonCode, l.reason_text AS ReasonText, l.transitioned_at AS TransitionedAt
      FROM grac_practice.entity_state_transition_log l
      LEFT JOIN grac_practice.entity_status_master fs ON fs.entity_status_id = l.from_status_id
      JOIN grac_practice.entity_status_master ts ON ts.entity_status_id = l.to_status_id
      LEFT JOIN grac_practice.organization_employee emp ON emp.employee_id = l.actor_employee_id
     WHERE l.entity_type = N'OsRelease' AND l.entity_id = @release_id
     ORDER BY l.transitioned_at DESC, l.transition_log_id DESC;
END
GO

-- Approved, active OS compatibility for one model (4.8); match rules as
-- sp_asset_model_firmware_list (426). ArchitectureMatch is 1 when the row
-- names no architecture or the model's.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_model_os_list
    @organization_id BIGINT,
    @model_id        BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @make_id INT, @type_id INT, @arch NVARCHAR(120), @found BIT = 0;
    SELECT @found = 1, @make_id = make_id, @type_id = asset_type_id, @arch = architecture
      FROM grac_practice.asset_model
     WHERE model_id = @model_id AND (organization_id IS NULL OR organization_id = @organization_id);
    IF @found = 0 THROW 54807, 'Model not found.', 1;

    SELECT c.compat_id AS CompatId, r.release_id AS ReleaseId, p.product_name AS ProductName, p.family AS Family,
           mk.make_name AS PublisherName, r.edition AS Edition, r.version AS Version, r.build AS Build,
           r.is_approved_baseline AS IsApprovedBaseline, s.status_code AS ReleaseStatusCode, s.status_name AS ReleaseStatusName,
           c.processor_architecture AS ProcessorArchitecture,
           CAST(CASE WHEN c.processor_architecture IS NULL OR c.processor_architecture = ISNULL(@arch, N'') THEN 1 ELSE 0 END AS BIT) AS ArchitectureMatch,
           CASE WHEN c.model_id IS NOT NULL THEN N'MODEL' WHEN c.make_id IS NOT NULL THEN N'MAKE' ELSE N'ASSET_TYPE' END AS MatchLevel,
           CASE WHEN fr.release_id IS NULL THEN NULL ELSE CONCAT(fp.product_name, N' ', fr.version) END AS MinFirmwareName, c.exclusions AS Exclusions, r.end_of_life_date AS EndOfLifeDate
      FROM grac_practice.asset_os_compatibility c
      JOIN grac_practice.asset_os_release r ON r.release_id = c.release_id
      JOIN grac_practice.asset_os_product p ON p.product_id = r.product_id
      JOIN grac_practice.asset_make mk ON mk.make_id = p.publisher_make_id
      JOIN grac_practice.entity_status_master s ON s.entity_status_id = r.current_status_id
      LEFT JOIN grac_practice.asset_firmware_release fr ON fr.release_id = c.min_firmware_release_id
      LEFT JOIN grac_practice.asset_firmware_product fp ON fp.product_id = fr.product_id
     WHERE c.is_active = 1 AND c.approval_status = N'APPROVED'
       AND (c.organization_id IS NULL OR c.organization_id = @organization_id)
       AND (r.organization_id IS NULL OR r.organization_id = @organization_id)
       AND s.status_code <> N'DRAFT'
       AND c.asset_type_id = @type_id
       AND (c.model_id = @model_id OR (c.model_id IS NULL AND (c.make_id = @make_id OR c.make_id IS NULL)))
     ORDER BY CASE c.model_id WHEN @model_id THEN 0 ELSE 1 END, p.product_name, r.version DESC;
END
GO

-- =====================================================================
-- 4. Writers (scope parameters as in 425 / 426)
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_os_product_save
    @organization_id         BIGINT,
    @shared                  BIT            = 0,
    @product_id              INT            = NULL,
    @publisher_make_id       INT,
    @family                  NVARCHAR(120)  = NULL,
    @product_name            NVARCHAR(200),
    @description             NVARCHAR(1000) = NULL,
    @status                  NVARCHAR(30)   = N'Active',
    @expected_record_version BIGINT         = NULL,
    @actor                   NVARCHAR(100)  = N'system',
    @out_product_id          INT            = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    SET @shared = ISNULL(@shared, 0);
    SET @family = NULLIF(LTRIM(RTRIM(@family)), N'');
    SET @product_name = NULLIF(LTRIM(RTRIM(@product_name)), N'');
    SET @status = CASE WHEN @status = N'Inactive' THEN N'Inactive' ELSE N'Active' END;

    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 54910, 'Organization not found.', 1;
    DECLARE @scope_org BIGINT = CASE WHEN @shared = 1 THEN NULL ELSE @organization_id END;
    DECLARE @found BIT = 0, @row_org BIGINT, @rv BIGINT, @old_make INT, @before NVARCHAR(MAX);
    IF @product_id IS NOT NULL
    BEGIN
        SELECT @found = 1, @row_org = organization_id, @rv = CONVERT(BIGINT, record_version), @old_make = publisher_make_id
          FROM grac_practice.asset_os_product WHERE product_id = @product_id;
        IF @found = 0 OR (@row_org IS NOT NULL AND @row_org <> @organization_id)
            THROW 54911, 'Operating-system product not found.', 1;
        IF ISNULL(@row_org, -1) <> ISNULL(@scope_org, -1)
            THROW 54914, 'This entry belongs to the shared catalogue; only the platform administrator can change it.', 1;
        IF @expected_record_version IS NOT NULL AND @expected_record_version <> @rv
            THROW 54915, 'This entry was changed by someone else. Reload and try again.', 1;
    END
    IF @product_name IS NULL THROW 54912, 'The operating-system product name is required.', 1;
    DECLARE @make_org BIGINT, @make_status NVARCHAR(30), @make_found BIT = 0;
    SELECT @make_found = 1, @make_org = organization_id, @make_status = status FROM grac_practice.asset_make WHERE make_id = @publisher_make_id;
    IF @make_found = 0 OR (@make_org IS NOT NULL AND @make_org <> @organization_id)
       OR (@scope_org IS NULL AND @make_org IS NOT NULL)
       OR (@make_status <> N'Active' AND ISNULL(@old_make, -1) <> @publisher_make_id)
        THROW 54916, 'Select an active publisher (make) from the catalogue; a shared product needs a shared make.', 1;
    IF @product_id IS NOT NULL AND @old_make <> @publisher_make_id
       AND EXISTS (SELECT 1 FROM grac_practice.asset_os_release WHERE product_id = @product_id)
        THROW 54916, 'The product already has releases, so its publisher cannot change.', 1;
    IF EXISTS (SELECT 1 FROM grac_practice.asset_os_product
                WHERE publisher_make_id = @publisher_make_id AND ISNULL(family, N'') = ISNULL(@family, N'')
                  AND product_name = @product_name AND product_id <> ISNULL(@product_id, -1)
                  AND (organization_id IS NULL OR organization_id = @organization_id))
        THROW 54913, 'This publisher already has an operating-system product with that family and name.', 1;

    SET @before = (SELECT publisher_make_id AS publisherMakeId, family, product_name AS productName, description, status
                     FROM grac_practice.asset_os_product WHERE product_id = @product_id FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
    BEGIN TRAN;
    IF @product_id IS NULL
    BEGIN
        DECLARE @make_name NVARCHAR(200);
        SELECT @make_name = make_name FROM grac_practice.asset_make WHERE make_id = @publisher_make_id;
        DECLARE @base NVARCHAR(160) = N'OS_' + ISNULL(grac_practice.fn_asset_make_code(CONCAT(@make_name, N' ', @product_name), 80), N'X'),
                @code NVARCHAR(160), @n INT = 1;
        SET @code = @base;
        WHILE EXISTS (SELECT 1 FROM grac_practice.asset_os_product WHERE product_code = @code)
        BEGIN
            SET @n = @n + 1;
            SET @code = @base + N'_' + CAST(@n AS NVARCHAR(10));
        END
        INSERT grac_practice.asset_os_product (organization_id, publisher_make_id, product_code, family, product_name, description, status, entered_by)
        VALUES (@scope_org, @publisher_make_id, @code, @family, @product_name, NULLIF(LTRIM(RTRIM(@description)), N''), @status, @actor);
        SET @out_product_id = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        UPDATE grac_practice.asset_os_product
           SET publisher_make_id = @publisher_make_id, family = @family, product_name = @product_name,
               description = NULLIF(LTRIM(RTRIM(@description)), N''), status = @status,
               updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE product_id = @product_id;
        SET @out_product_id = @product_id;
    END
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-os-product', @out_product_id, CASE WHEN @product_id IS NULL THEN N'ADD' ELSE N'SAVE' END, @before,
            (SELECT @scope_org AS organizationId, @publisher_make_id AS publisherMakeId, @family AS family,
                    @product_name AS productName, @description AS description, @status AS status FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            N'Active', @actor);
    COMMIT;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_asset_os_release_save
    @organization_id             BIGINT,
    @shared                      BIT            = 0,
    @release_id                  BIGINT         = NULL,
    @product_id                  INT,
    @edition                     NVARCHAR(100)  = NULL,
    @version                     NVARCHAR(100),
    @build                       NVARCHAR(100)  = NULL,
    @architecture                NVARCHAR(60)   = NULL,
    @release_date                DATE           = NULL,
    @mainstream_support_end_date DATE           = NULL,
    @extended_support_end_date   DATE           = NULL,
    @security_update_end_date    DATE           = NULL,
    @end_of_life_date            DATE           = NULL,
    @servicing_channel           NVARCHAR(100)  = NULL,
    @feature_version             NVARCHAR(100)  = NULL,
    @patch_level                 NVARCHAR(100)  = NULL,
    @latest_approved_build       NVARCHAR(100)  = NULL,
    @minimum_compliant_build     NVARCHAR(100)  = NULL,
    @source_reference            NVARCHAR(500)  = NULL,
    @verified_date               DATE           = NULL,
    @verified_by                 NVARCHAR(200)  = NULL,
    @is_approved_baseline        BIT            = 0,
    @exception_note              NVARCHAR(1000) = NULL,
    @replacement_release_id      BIGINT         = NULL,
    @replacement_path            NVARCHAR(500)  = NULL,
    @change_reason               NVARCHAR(1000) = NULL,
    @expected_record_version     BIGINT         = NULL,
    @actor_employee_id           BIGINT         = NULL,
    @actor                       NVARCHAR(100)  = N'system',
    @out_release_id              BIGINT         = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    SET @shared = ISNULL(@shared, 0);
    SET @is_approved_baseline = ISNULL(@is_approved_baseline, 0);
    SET @edition = NULLIF(LTRIM(RTRIM(@edition)), N'');
    SET @version = NULLIF(LTRIM(RTRIM(@version)), N'');
    SET @build = NULLIF(LTRIM(RTRIM(@build)), N'');
    SET @architecture = NULLIF(LTRIM(RTRIM(@architecture)), N'');
    SET @source_reference = NULLIF(LTRIM(RTRIM(@source_reference)), N'');
    SET @change_reason = NULLIF(LTRIM(RTRIM(@change_reason)), N'');

    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 54910, 'Organization not found.', 1;
    DECLARE @scope_org BIGINT = CASE WHEN @shared = 1 THEN NULL ELSE @organization_id END;

    DECLARE @old TABLE (organization_id BIGINT, product_id INT, edition NVARCHAR(100), version NVARCHAR(100),
        build NVARCHAR(100), architecture NVARCHAR(60), release_date DATE, mainstream_support_end_date DATE,
        extended_support_end_date DATE, security_update_end_date DATE, end_of_life_date DATE, status_code NVARCHAR(60), rv BIGINT);
    DECLARE @found BIT = 0, @row_org BIGINT, @status_code NVARCHAR(60), @rv BIGINT, @before NVARCHAR(MAX);
    IF @release_id IS NOT NULL
    BEGIN
        INSERT @old
        SELECT r.organization_id, r.product_id, r.edition, r.version, r.build, r.architecture, r.release_date,
               r.mainstream_support_end_date, r.extended_support_end_date, r.security_update_end_date, r.end_of_life_date,
               s.status_code, CONVERT(BIGINT, r.record_version)
          FROM grac_practice.asset_os_release r
          JOIN grac_practice.entity_status_master s ON s.entity_status_id = r.current_status_id
         WHERE r.release_id = @release_id;
        SELECT @found = 1, @row_org = organization_id, @status_code = status_code, @rv = rv FROM @old;
        IF @found = 0 OR (@row_org IS NOT NULL AND @row_org <> @organization_id)
            THROW 54917, 'Operating-system release not found.', 1;
        IF ISNULL(@row_org, -1) <> ISNULL(@scope_org, -1)
            THROW 54914, 'This entry belongs to the shared catalogue; only the platform administrator can change it.', 1;
        IF @expected_record_version IS NOT NULL AND @expected_record_version <> @rv
            THROW 54915, 'This entry was changed by someone else. Reload and try again.', 1;
        IF @status_code <> N'DRAFT' AND EXISTS (
            SELECT 1 FROM @old o
             WHERE o.product_id <> @product_id OR o.version <> ISNULL(@version, N'')
                OR ISNULL(o.edition, N'') <> ISNULL(@edition, N'') OR ISNULL(o.build, N'') <> ISNULL(@build, N'')
                OR ISNULL(o.architecture, N'') <> ISNULL(@architecture, N''))
            THROW 54922, 'The release has been approved: product, edition, version, build and architecture can no longer change.', 1;
    END
    IF @version IS NULL THROW 54918, 'The operating-system version is required.', 1;

    DECLARE @prod_org BIGINT, @prod_status NVARCHAR(30), @prod_found BIT = 0;
    SELECT @prod_found = 1, @prod_org = organization_id, @prod_status = status FROM grac_practice.asset_os_product WHERE product_id = @product_id;
    IF @prod_found = 0 OR (@prod_org IS NOT NULL AND @prod_org <> @organization_id)
        THROW 54911, 'Operating-system product not found.', 1;
    IF (@scope_org IS NULL AND @prod_org IS NOT NULL)
       OR (@prod_status <> N'Active' AND NOT EXISTS (SELECT 1 FROM @old WHERE product_id = @product_id))
        THROW 54911, 'Select an active operating-system product; a shared release needs a shared product.', 1;
    IF @release_date IS NOT NULL AND (
          @mainstream_support_end_date < @release_date OR @extended_support_end_date < @release_date
       OR @security_update_end_date    < @release_date OR @end_of_life_date          < @release_date)
        THROW 54920, 'Support-end and end-of-life dates cannot precede the release date.', 1;
    IF @replacement_release_id IS NOT NULL AND (
           @replacement_release_id = ISNULL(@release_id, -1)
        OR NOT EXISTS (SELECT 1 FROM grac_practice.asset_os_release
                        WHERE release_id = @replacement_release_id
                          AND (organization_id IS NULL OR (@scope_org IS NOT NULL AND organization_id = @organization_id))))
        THROW 54932, 'The replacement must be another release in the catalogue for this scope.', 1;
    IF EXISTS (SELECT 1 FROM grac_practice.asset_os_release r
                WHERE r.product_id = @product_id AND r.release_id <> ISNULL(@release_id, -1)
                  AND (r.organization_id IS NULL OR r.organization_id = @organization_id)
                  AND r.version = @version AND ISNULL(r.edition, N'') = ISNULL(@edition, N'')
                  AND ISNULL(r.build, N'') = ISNULL(@build, N'') AND ISNULL(r.architecture, N'') = ISNULL(@architecture, N''))
        THROW 54919, 'This product already has a release with the same edition, version, build and architecture.', 1;

    DECLARE @changes TABLE (milestone_code NVARCHAR(60), before_value NVARCHAR(200), after_value NVARCHAR(200));
    IF @release_id IS NOT NULL
    BEGIN
        INSERT @changes (milestone_code, before_value, after_value)
        SELECT v.code, v.b, v.a
          FROM @old o
         CROSS APPLY (VALUES
            (N'RELEASE_DATE',            CONVERT(NVARCHAR(10), o.release_date, 23),                CONVERT(NVARCHAR(10), @release_date, 23)),
            (N'END_MAINSTREAM_SUPPORT',  CONVERT(NVARCHAR(10), o.mainstream_support_end_date, 23), CONVERT(NVARCHAR(10), @mainstream_support_end_date, 23)),
            (N'END_EXTENDED_SUPPORT',    CONVERT(NVARCHAR(10), o.extended_support_end_date, 23),   CONVERT(NVARCHAR(10), @extended_support_end_date, 23)),
            (N'END_SECURITY_UPDATES',    CONVERT(NVARCHAR(10), o.security_update_end_date, 23),    CONVERT(NVARCHAR(10), @security_update_end_date, 23)),
            (N'END_OF_LIFE_DATE',        CONVERT(NVARCHAR(10), o.end_of_life_date, 23),            CONVERT(NVARCHAR(10), @end_of_life_date, 23))
         ) AS v(code, b, a)
         WHERE ISNULL(v.b, N'') <> ISNULL(v.a, N'');
        IF @change_reason IS NULL AND EXISTS (SELECT 1 FROM @changes WHERE before_value IS NOT NULL)
            THROW 54921, 'A reason is required to change a lifecycle date that already had a value.', 1;
    END

    SET @before = (SELECT product_id AS productId, edition, version, build, architecture, release_date AS releaseDate,
                          mainstream_support_end_date AS mainstreamSupportEndDate, extended_support_end_date AS extendedSupportEndDate,
                          security_update_end_date AS securityUpdateEndDate, end_of_life_date AS endOfLifeDate,
                          latest_approved_build AS latestApprovedBuild, minimum_compliant_build AS minimumCompliantBuild,
                          is_approved_baseline AS isApprovedBaseline, source_reference AS sourceReference
                     FROM grac_practice.asset_os_release WHERE release_id = @release_id FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    DECLARE @draft_id INT = grac_practice.fn_get_entity_status_id(N'OsRelease', N'DRAFT');
    DECLARE @to_status_id INT, @log_id BIGINT;

    BEGIN TRAN;
    IF @release_id IS NULL
    BEGIN
        DECLARE @product_code NVARCHAR(100);
        SELECT @product_code = product_code FROM grac_practice.asset_os_product WHERE product_id = @product_id;
        DECLARE @base NVARCHAR(160) = LEFT(@product_code, 80) + N'_' + ISNULL(grac_practice.fn_asset_make_code(
                    CONCAT(@edition, N' ', @version, N' ', @build, N' ', @architecture), 50), N'X'),
                @code NVARCHAR(160), @n INT = 1;
        SET @code = @base;
        WHILE EXISTS (SELECT 1 FROM grac_practice.asset_os_release WHERE release_code = @code)
        BEGIN
            SET @n = @n + 1;
            SET @code = @base + N'_' + CAST(@n AS NVARCHAR(10));
        END
        INSERT grac_practice.asset_os_release
            (organization_id, product_id, release_code, edition, version, build, architecture, release_date,
             mainstream_support_end_date, extended_support_end_date, security_update_end_date, end_of_life_date,
             servicing_channel, feature_version, patch_level, latest_approved_build, minimum_compliant_build,
             source_reference, verified_date, verified_by, is_approved_baseline, exception_note, replacement_release_id,
             replacement_path, current_status_id, draft_edited_by, entered_by)
        VALUES (@scope_org, @product_id, @code, @edition, @version, @build, @architecture, @release_date,
                @mainstream_support_end_date, @extended_support_end_date, @security_update_end_date, @end_of_life_date,
                NULLIF(LTRIM(RTRIM(@servicing_channel)), N''), NULLIF(LTRIM(RTRIM(@feature_version)), N''),
                NULLIF(LTRIM(RTRIM(@patch_level)), N''), NULLIF(LTRIM(RTRIM(@latest_approved_build)), N''),
                NULLIF(LTRIM(RTRIM(@minimum_compliant_build)), N''), @source_reference, @verified_date,
                NULLIF(LTRIM(RTRIM(@verified_by)), N''), @is_approved_baseline, NULLIF(LTRIM(RTRIM(@exception_note)), N''),
                @replacement_release_id, NULLIF(LTRIM(RTRIM(@replacement_path)), N''), @draft_id, @actor, @actor);
        SET @out_release_id = SCOPE_IDENTITY();
        EXEC grac_practice.sp_pm_state_transition
             @entity_type = N'OsRelease', @entity_id = @out_release_id,
             @from_status_code = NULL, @to_status_code = N'DRAFT',
             @actor_employee_id = @actor_employee_id, @actor_role_code = NULL,
             @reason_code = N'CREATED', @reason_text = NULL,
             @to_status_id = @to_status_id OUTPUT, @transition_log_id = @log_id OUTPUT;
    END
    ELSE
    BEGIN
        UPDATE grac_practice.asset_os_release
           SET product_id = @product_id, edition = @edition, version = @version, build = @build, architecture = @architecture,
               release_date = @release_date, mainstream_support_end_date = @mainstream_support_end_date,
               extended_support_end_date = @extended_support_end_date, security_update_end_date = @security_update_end_date,
               end_of_life_date = @end_of_life_date, servicing_channel = NULLIF(LTRIM(RTRIM(@servicing_channel)), N''),
               feature_version = NULLIF(LTRIM(RTRIM(@feature_version)), N''), patch_level = NULLIF(LTRIM(RTRIM(@patch_level)), N''),
               latest_approved_build = NULLIF(LTRIM(RTRIM(@latest_approved_build)), N''),
               minimum_compliant_build = NULLIF(LTRIM(RTRIM(@minimum_compliant_build)), N''),
               source_reference = @source_reference, verified_date = @verified_date,
               verified_by = NULLIF(LTRIM(RTRIM(@verified_by)), N''), is_approved_baseline = @is_approved_baseline,
               exception_note = NULLIF(LTRIM(RTRIM(@exception_note)), N''), replacement_release_id = @replacement_release_id,
               replacement_path = NULLIF(LTRIM(RTRIM(@replacement_path)), N''),
               draft_edited_by = CASE WHEN @status_code = N'DRAFT' THEN @actor ELSE draft_edited_by END,
               updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE release_id = @release_id;
        SET @out_release_id = @release_id;
        INSERT grac_practice.technology_lifecycle_event
            (entity_type, entity_id, milestone_code, before_value, after_value, source, reason, impact_count, entered_by)
        SELECT N'OS', @release_id, milestone_code, before_value, after_value, @source_reference, @change_reason, NULL, @actor
          FROM @changes;
    END
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-os-release', @out_release_id, CASE WHEN @release_id IS NULL THEN N'ADD' ELSE N'SAVE' END, @before,
            (SELECT @scope_org AS organizationId, @product_id AS productId, @edition AS edition, @version AS version,
                    @build AS build, @architecture AS architecture, @release_date AS releaseDate,
                    @mainstream_support_end_date AS mainstreamSupportEndDate, @extended_support_end_date AS extendedSupportEndDate,
                    @security_update_end_date AS securityUpdateEndDate, @end_of_life_date AS endOfLifeDate,
                    @latest_approved_build AS latestApprovedBuild, @minimum_compliant_build AS minimumCompliantBuild,
                    @is_approved_baseline AS isApprovedBaseline, @source_reference AS sourceReference,
                    @change_reason AS changeReason FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            N'Active', @actor);
    COMMIT;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_asset_os_release_transition
    @organization_id         BIGINT,
    @shared                  BIT            = 0,
    @release_id              BIGINT,
    @to_status_code          NVARCHAR(60),
    @reason_text             NVARCHAR(1000) = NULL,
    @expected_record_version BIGINT         = NULL,
    @actor_employee_id       BIGINT         = NULL,
    @actor                   NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    SET @shared = ISNULL(@shared, 0);
    SET @to_status_code = UPPER(LTRIM(RTRIM(ISNULL(@to_status_code, N''))));
    SET @reason_text = NULLIF(LTRIM(RTRIM(@reason_text)), N'');

    DECLARE @found BIT = 0, @from NVARCHAR(60), @rv BIGINT, @row_org BIGINT, @editor NVARCHAR(100), @source NVARCHAR(500),
            @prod_status NVARCHAR(30);
    SELECT @found = 1, @from = s.status_code, @rv = CONVERT(BIGINT, r.record_version), @row_org = r.organization_id,
           @editor = r.draft_edited_by, @source = r.source_reference, @prod_status = p.status
      FROM grac_practice.asset_os_release r
      JOIN grac_practice.entity_status_master s ON s.entity_status_id = r.current_status_id
      JOIN grac_practice.asset_os_product p ON p.product_id = r.product_id
     WHERE r.release_id = @release_id;
    IF @found = 0 OR (@row_org IS NOT NULL AND @row_org <> @organization_id)
        THROW 54917, 'Operating-system release not found.', 1;
    IF ISNULL(@row_org, -1) <> CASE WHEN @shared = 1 THEN -1 ELSE @organization_id END
        THROW 54914, 'This entry belongs to the shared catalogue; only the platform administrator can change it.', 1;
    IF @expected_record_version IS NOT NULL AND @expected_record_version <> @rv
        THROW 54915, 'This entry was changed by someone else. Reload and try again.', 1;
    IF @from = N'APPROACHING_EOS' AND @to_status_code = N'EXTENDED_SUPPORT' AND @reason_text IS NULL
        THROW 54925, 'A reason is required to record a support extension.', 1;
    IF @from = N'DRAFT' AND @to_status_code = N'APPROVED'
    BEGIN
        IF @source IS NULL
            THROW 54923, 'Add the source reference (vendor lifecycle page or notice) before approving.', 1;
        IF @prod_status <> N'Active'
            THROW 54923, 'The operating-system product is inactive. Reactivate it before approving.', 1;
        IF @editor = @actor
            THROW 54924, 'Segregation of duties: the person who last edited this draft cannot approve it.', 1;
    END

    DECLARE @reason_code NVARCHAR(60) = CASE WHEN @to_status_code = N'APPROVED' THEN N'APPROVED' ELSE N'STATUS_CHANGED' END;
    DECLARE @to_status_id INT, @log_id BIGINT;

    BEGIN TRAN;
    EXEC grac_practice.sp_pm_state_transition
         @entity_type = N'OsRelease', @entity_id = @release_id,
         @from_status_code = @from, @to_status_code = @to_status_code,
         @actor_employee_id = @actor_employee_id, @actor_role_code = NULL,
         @reason_code = @reason_code, @reason_text = @reason_text,
         @to_status_id = @to_status_id OUTPUT, @transition_log_id = @log_id OUTPUT;
    UPDATE grac_practice.asset_os_release
       SET current_status_id = @to_status_id,
           approved_by = CASE WHEN @to_status_code = N'APPROVED' THEN @actor ELSE approved_by END,
           approved_dt = CASE WHEN @to_status_code = N'APPROVED' THEN SYSUTCDATETIME() ELSE approved_dt END,
           updated_by = @actor, updated_dt = SYSUTCDATETIME()
     WHERE release_id = @release_id;
    COMMIT;

    SELECT @release_id AS ReleaseId, @to_status_code AS StatusCode;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_asset_os_compat_save
    @organization_id         BIGINT,
    @shared                  BIT            = 0,
    @compat_id               BIGINT         = NULL,
    @release_id              BIGINT,
    @asset_type_id           INT,
    @make_id                 INT            = NULL,
    @model_id                BIGINT         = NULL,
    @processor_architecture  NVARCHAR(60)   = NULL,
    @min_firmware_release_id BIGINT         = NULL,
    @firmware_prerequisite   NVARCHAR(500)  = NULL,
    @exclusions              NVARCHAR(1000) = NULL,
    @evidence                NVARCHAR(1000) = NULL,
    @reviewer                NVARCHAR(200)  = NULL,
    @is_active               BIT            = 1,
    @expected_record_version BIGINT         = NULL,
    @actor                   NVARCHAR(100)  = N'system',
    @out_compat_id           BIGINT         = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    SET @shared = ISNULL(@shared, 0);
    SET @is_active = ISNULL(@is_active, 1);
    SET @processor_architecture = NULLIF(LTRIM(RTRIM(@processor_architecture)), N'');

    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 54910, 'Organization not found.', 1;
    DECLARE @scope_org BIGINT = CASE WHEN @shared = 1 THEN NULL ELSE @organization_id END;
    DECLARE @found BIT = 0, @row_org BIGINT, @rv BIGINT, @before NVARCHAR(MAX), @old_release BIGINT;
    IF @compat_id IS NOT NULL
    BEGIN
        SELECT @found = 1, @row_org = organization_id, @rv = CONVERT(BIGINT, record_version), @old_release = release_id
          FROM grac_practice.asset_os_compatibility WHERE compat_id = @compat_id;
        IF @found = 0 OR (@row_org IS NOT NULL AND @row_org <> @organization_id)
            THROW 54926, 'Compatibility record not found.', 1;
        IF ISNULL(@row_org, -1) <> ISNULL(@scope_org, -1)
            THROW 54914, 'This entry belongs to the shared catalogue; only the platform administrator can change it.', 1;
        IF @expected_record_version IS NOT NULL AND @expected_record_version <> @rv
            THROW 54915, 'This entry was changed by someone else. Reload and try again.', 1;
        IF @old_release <> @release_id THROW 54926, 'A compatibility record cannot move to another release.', 1;
    END

    DECLARE @rel_org BIGINT, @rel_found BIT = 0;
    SELECT @rel_found = 1, @rel_org = organization_id FROM grac_practice.asset_os_release WHERE release_id = @release_id;
    IF @rel_found = 0 OR (@rel_org IS NOT NULL AND @rel_org <> @organization_id) OR (@scope_org IS NULL AND @rel_org IS NOT NULL)
        THROW 54917, 'Operating-system release not found (a shared compatibility record needs a shared release).', 1;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.dependency_asset_type_master WHERE asset_type_id = @asset_type_id)
        THROW 54927, 'Select a valid asset type.', 1;
    IF @make_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM grac_practice.asset_make WHERE make_id = @make_id
           AND (organization_id IS NULL OR (@scope_org IS NOT NULL AND organization_id = @organization_id)))
        THROW 54928, 'The make is not in the catalogue for this scope.', 1;
    IF @model_id IS NOT NULL
    BEGIN
        DECLARE @m_make INT, @m_type INT, @m_found BIT = 0;
        SELECT @m_found = 1, @m_make = make_id, @m_type = asset_type_id FROM grac_practice.asset_model
         WHERE model_id = @model_id AND (organization_id IS NULL OR (@scope_org IS NOT NULL AND organization_id = @organization_id));
        IF @m_found = 0 THROW 54928, 'The model is not in the catalogue for this scope.', 1;
        IF @m_type <> @asset_type_id OR (@make_id IS NOT NULL AND @make_id <> @m_make)
            THROW 54928, 'The model belongs to a different make or asset type.', 1;
        SET @make_id = @m_make;
    END
    IF @min_firmware_release_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM grac_practice.asset_firmware_release
         WHERE release_id = @min_firmware_release_id
           AND (organization_id IS NULL OR (@scope_org IS NOT NULL AND organization_id = @organization_id)))
        THROW 54929, 'The firmware prerequisite must be a firmware release in the catalogue for this scope.', 1;

    IF @is_active = 1 AND EXISTS (
        SELECT 1 FROM grac_practice.asset_os_compatibility c
         WHERE c.release_id = @release_id AND c.is_active = 1 AND c.compat_id <> ISNULL(@compat_id, -1)
           AND (c.organization_id IS NULL OR c.organization_id = @organization_id)
           AND c.asset_type_id = @asset_type_id AND ISNULL(c.make_id, -1) = ISNULL(@make_id, -1)
           AND ISNULL(c.model_id, -1) = ISNULL(@model_id, -1)
           AND ISNULL(c.processor_architecture, N'') = ISNULL(@processor_architecture, N''))
        THROW 54930, 'An active compatibility record already exists for this release, asset type, make, model and architecture.', 1;

    SET @before = (SELECT asset_type_id AS assetTypeId, make_id AS makeId, model_id AS modelId,
                          processor_architecture AS processorArchitecture, min_firmware_release_id AS minFirmwareReleaseId,
                          firmware_prerequisite AS firmwarePrerequisite, exclusions, evidence, reviewer,
                          approval_status AS approvalStatus, is_active AS isActive
                     FROM grac_practice.asset_os_compatibility WHERE compat_id = @compat_id FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
    BEGIN TRAN;
    IF @compat_id IS NULL
    BEGIN
        INSERT grac_practice.asset_os_compatibility
            (organization_id, release_id, asset_type_id, make_id, model_id, processor_architecture, min_firmware_release_id,
             firmware_prerequisite, exclusions, evidence, reviewer, approval_status, edited_by, is_active, entered_by)
        VALUES (@scope_org, @release_id, @asset_type_id, @make_id, @model_id, @processor_architecture, @min_firmware_release_id,
                NULLIF(LTRIM(RTRIM(@firmware_prerequisite)), N''), NULLIF(LTRIM(RTRIM(@exclusions)), N''),
                NULLIF(LTRIM(RTRIM(@evidence)), N''), NULLIF(LTRIM(RTRIM(@reviewer)), N''), N'DRAFT', @actor, @is_active, @actor);
        SET @out_compat_id = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        UPDATE grac_practice.asset_os_compatibility
           SET asset_type_id = @asset_type_id, make_id = @make_id, model_id = @model_id,
               processor_architecture = @processor_architecture, min_firmware_release_id = @min_firmware_release_id,
               firmware_prerequisite = NULLIF(LTRIM(RTRIM(@firmware_prerequisite)), N''),
               exclusions = NULLIF(LTRIM(RTRIM(@exclusions)), N''), evidence = NULLIF(LTRIM(RTRIM(@evidence)), N''),
               reviewer = NULLIF(LTRIM(RTRIM(@reviewer)), N''), is_active = @is_active,
               approval_status = N'DRAFT', approved_by = NULL, approved_dt = NULL, edited_by = @actor,
               updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE compat_id = @compat_id;
        SET @out_compat_id = @compat_id;
    END
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-os-compat', @out_compat_id, CASE WHEN @compat_id IS NULL THEN N'ADD' ELSE N'SAVE' END, @before,
            (SELECT @scope_org AS organizationId, @release_id AS releaseId, @asset_type_id AS assetTypeId, @make_id AS makeId,
                    @model_id AS modelId, @processor_architecture AS processorArchitecture,
                    @min_firmware_release_id AS minFirmwareReleaseId, @firmware_prerequisite AS firmwarePrerequisite,
                    @exclusions AS exclusions, @evidence AS evidence, @reviewer AS reviewer, @is_active AS isActive
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            N'Active', @actor);
    COMMIT;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_asset_os_compat_approve
    @organization_id         BIGINT,
    @shared                  BIT           = 0,
    @compat_id               BIGINT,
    @expected_record_version BIGINT        = NULL,
    @actor                   NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    SET @shared = ISNULL(@shared, 0);
    DECLARE @found BIT = 0, @row_org BIGINT, @rv BIGINT, @approval NVARCHAR(20), @editor NVARCHAR(100), @evidence NVARCHAR(1000),
            @active BIT, @rel_status NVARCHAR(60);
    SELECT @found = 1, @row_org = c.organization_id, @rv = CONVERT(BIGINT, c.record_version), @approval = c.approval_status,
           @editor = c.edited_by, @evidence = c.evidence, @active = c.is_active, @rel_status = s.status_code
      FROM grac_practice.asset_os_compatibility c
      JOIN grac_practice.asset_os_release r ON r.release_id = c.release_id
      JOIN grac_practice.entity_status_master s ON s.entity_status_id = r.current_status_id
     WHERE c.compat_id = @compat_id;
    IF @found = 0 OR (@row_org IS NOT NULL AND @row_org <> @organization_id)
        THROW 54926, 'Compatibility record not found.', 1;
    IF ISNULL(@row_org, -1) <> CASE WHEN @shared = 1 THEN -1 ELSE @organization_id END
        THROW 54914, 'This entry belongs to the shared catalogue; only the platform administrator can change it.', 1;
    IF @expected_record_version IS NOT NULL AND @expected_record_version <> @rv
        THROW 54915, 'This entry was changed by someone else. Reload and try again.', 1;
    IF @approval = N'APPROVED' THROW 54931, 'This compatibility record is already approved.', 1;
    IF @active = 0 THROW 54931, 'Reactivate the record before approving it.', 1;
    IF @evidence IS NULL THROW 54931, 'Add the evidence (vendor matrix, release notes, test or internal approval) before approving.', 1;
    IF @rel_status = N'DRAFT' THROW 54931, 'Approve the operating-system release first; a draft release cannot carry approved compatibility.', 1;
    IF @editor = @actor THROW 54924, 'Segregation of duties: the person who last edited this record cannot approve it.', 1;

    BEGIN TRAN;
    UPDATE grac_practice.asset_os_compatibility
       SET approval_status = N'APPROVED', approved_by = @actor, approved_dt = SYSUTCDATETIME(),
           updated_by = @actor, updated_dt = SYSUTCDATETIME()
     WHERE compat_id = @compat_id;
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-os-compat', @compat_id, N'APPROVE', N'{"approvalStatus":"DRAFT"}', N'{"approvalStatus":"APPROVED"}', N'Active', @actor);
    COMMIT;
END
GO
PRINT '427: operating-system procedures created.';
GO

-- =====================================================================
-- Verification
-- =====================================================================
SELECT '427-a tables present' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.asset_os_product','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.asset_os_release','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.asset_os_compatibility','U') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '427-b OsRelease lifecycle (7 statuses, 18 rules)',
       CASE WHEN (SELECT COUNT(*) FROM grac_practice.entity_status_master WHERE entity_type = N'OsRelease') = 7
             AND (SELECT COUNT(*) FROM grac_practice.entity_state_transition_rule WHERE entity_type = N'OsRelease') = 18
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '427-c procedures present',
       CASE WHEN (SELECT COUNT(*) FROM sys.procedures WHERE SCHEMA_NAME(schema_id) = 'grac_practice'
                   AND name IN ('sp_asset_os_list', 'sp_asset_os_release_get', 'sp_asset_model_os_list',
                                'sp_asset_os_product_save', 'sp_asset_os_release_save', 'sp_asset_os_release_transition',
                                'sp_asset_os_compat_save', 'sp_asset_os_compat_approve')) = 8 THEN 'PASS' ELSE 'FAIL' END;
GO

-- =====================================================================
-- UAT (after deploying the API + Web build)
--   1. Technology Catalogue -> Operating Systems -> Add Product:
--      publisher = a make, family "Windows", name "Windows Server".
--   2. Add Release: edition Datacenter, version 2022, architecture x64;
--      mainstream support end before the release date -- refused (54920).
--   3. Approve as the last editor -- refused (54924); without a source --
--      refused (54923); as another admin -- Approved; then Supported.
--   4. Change the version of the approved release -- refused (54922);
--      change extended support end without a reason -- refused (54921);
--      with a reason -- saved and shown in History.
--   5. Mark Approaching EOS, then Extended Support without a reason --
--      refused (54925); with one -- accepted.
--   6. Compatibility: add a row for the asset type and model with a
--      minimum firmware release and exclusions; approve without evidence
--      -- refused (54931); with evidence by another user -- Approved.
--   7. Models -> open the model -> Operating Systems: the approved release
--      is listed with the architecture match.
-- =====================================================================
