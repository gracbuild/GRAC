-- =====================================================================
-- 426  Technology catalogue: firmware products, releases and
--      compatibility (Asset & Contract Management, Phase 3 increment 2)
--
-- REQUEST
-- -------
--   BRD v1.7 4.4 (Firmware Catalog and Many-to-Many Mapping), 4.8
--   ("only approved compatibility mappings can drive automated
--   recommendations", "recommended targets must match type, make, model
--   and hardware revision", "lifecycle dates cannot be overwritten
--   without reason and history", "end-of-support dates cannot precede
--   release dates") and section 15 (FirmwareProduct, FirmwareRelease,
--   FirmwareCompatibility). Builds on 425 (makes, models,
--   technology_lifecycle_event). Plan in docs/asset-contract-management.md.
--
-- WHAT THIS DOES
-- --------------
--   1. asset_firmware_product -- publisher (a make: 4.2 "firmware
--      publishers") and product name.
--   2. asset_firmware_release -- 4.4 field groups: identity (version,
--      build, branch / train, edition), lifecycle dates (release,
--      engineering-support end, standard-support end, security-fix end,
--      end of life), security (known vulnerabilities, minimum safe
--      version, upgrade urgency), package (location, checksum, signature,
--      release notes), governance (source, verified date, reviewer,
--      approval).
--   3. Release status = the BRD list, on the state-machine framework
--      (entity FirmwareRelease): Draft -> Approved, then Recommended /
--      Supported / Deprecated / EOS / EOL; Withdrawn from any status
--      (reason); Withdrawn -> Draft (reopen, reason). Approval needs
--      APPROVE, a source reference, and an approver other than the
--      person who last edited the draft. After approval the identity
--      (product, version, build, branch, edition) is locked; lifecycle
--      dates stay editable and overwriting one needs a reason, recorded
--      in technology_lifecycle_event (entity FIRMWARE).
--   4. asset_firmware_compatibility -- one explicit row per firmware
--      release + asset type (+ optional make, model, hardware revision):
--      status Certified / Supported / Conditional / Unsupported /
--      Unknown, upgrade path, effective dates, evidence, reviewer. Rows
--      are Draft until approved (evidence required, approver other than
--      the last editor); editing an approved row returns it to Draft so
--      it is approved again. Rows are deactivated, never deleted.
--   5. sp_asset_model_firmware_list -- the approved, in-effect
--      compatibility for a model (rows naming the model, or its make and
--      asset type with no model, or the asset type alone), with the
--      release status and whether the hardware revision matches. This is
--      the one read later phases (recommendations, campaigns) will use.
--   6. Scope as 425: organization_id NULL = shared catalogue (platform
--      administrator), otherwise the organization's own rows; an
--      organization may map a shared release to its own models.
--
-- DUPLICATE RULES
--   Product: publisher + name unique among visible products.
--   Release: product + version + build + branch + edition unique.
--   Compatibility: release + asset type + make + model + hardware
--   revision unique among active visible rows.
--
-- NOT DONE HERE: OS catalogue (next increment); installed firmware per
--   asset and the Unknown-version assessment gap (4.6 / 4.8 -- needs the
--   Asset Register, Phase 4); campaigns (4.7 steps 4-8).
--
-- ERROR NUMBERS: 54850-54889
--   54850 organization not found          54851 product not found
--   54852 product name required           54853 product already exists
--   54854 shared-catalogue scope mismatch 54855 changed by someone else
--   54856 publisher (make) not usable     54857 release not found
--   54858 version required                54859 release already exists
--   54860 date sequence                   54861 reason required (milestone overwrite)
--   54862 identity locked                 54863 not ready to approve
--   54864 segregation of duties           54865 reason required (status move)
--   54866 compatibility row not found     54867 asset type not valid
--   54868 make / model not consistent     54869 compatibility status not valid
--   54870 compatibility duplicate         54871 effective dates
--   54872 compatibility not ready to approve
--
-- ALSO EDITED: API (AssetConfig service / controller / models), Web
--   proxy, asset-tech-catalog partial + script (Firmware tab; compatible
--   firmware on the model). No new menu row.
-- DEPENDS ON: 425.
-- Rollback: 426_asset_firmware_catalog_rollback.sql
-- Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.asset_make','U') IS NULL
   OR OBJECT_ID('grac_practice.asset_model','U') IS NULL
   OR OBJECT_ID('grac_practice.technology_lifecycle_event','U') IS NULL
   OR OBJECT_ID('grac_practice.fn_asset_taxonomy_selectable') IS NULL
BEGIN
    RAISERROR('ABORT (426): run 424 and 425 first.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. Tables
-- =====================================================================
IF OBJECT_ID('grac_practice.asset_firmware_product','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_firmware_product (
        product_id        INT            IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_asset_fw_product PRIMARY KEY,
        organization_id   BIGINT         NULL
            CONSTRAINT fk_pm_asset_fw_product_org REFERENCES grac_practice.organization(organization_id),
        publisher_make_id INT            NOT NULL
            CONSTRAINT fk_pm_asset_fw_product_make REFERENCES grac_practice.asset_make(make_id),
        product_code      NVARCHAR(100)  NOT NULL CONSTRAINT uq_pm_asset_fw_product_code UNIQUE,
        product_name      NVARCHAR(200)  NOT NULL,
        description       NVARCHAR(1000) NULL,
        status            NVARCHAR(30)   NOT NULL CONSTRAINT df_pm_asset_fw_product_status DEFAULT N'Active'
            CONSTRAINT ck_pm_asset_fw_product_status CHECK (status IN (N'Active', N'Inactive')),
        entered_by        NVARCHAR(100)  NOT NULL CONSTRAINT df_pm_asset_fw_product_eby DEFAULT N'system',
        entered_dt        DATETIME2      NOT NULL CONSTRAINT df_pm_asset_fw_product_edt DEFAULT SYSUTCDATETIME(),
        updated_by        NVARCHAR(100)  NULL,
        updated_dt        DATETIME2      NULL,
        record_version    ROWVERSION     NOT NULL
    );
    PRINT '426: asset_firmware_product created.';
END
GO

IF OBJECT_ID('grac_practice.asset_firmware_release','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_firmware_release (
        release_id                   BIGINT         IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_asset_fw_release PRIMARY KEY,
        organization_id              BIGINT         NULL
            CONSTRAINT fk_pm_asset_fw_release_org REFERENCES grac_practice.organization(organization_id),
        product_id                   INT            NOT NULL
            CONSTRAINT fk_pm_asset_fw_release_product REFERENCES grac_practice.asset_firmware_product(product_id),
        release_code                 NVARCHAR(140)  NOT NULL CONSTRAINT uq_pm_asset_fw_release_code UNIQUE,
        version                      NVARCHAR(100)  NOT NULL,
        build                        NVARCHAR(100)  NULL,
        branch_train                 NVARCHAR(100)  NULL,
        edition                      NVARCHAR(100)  NULL,
        release_date                 DATE           NULL,
        engineering_support_end_date DATE           NULL,
        standard_support_end_date    DATE           NULL,
        security_fix_end_date        DATE           NULL,
        end_of_life_date             DATE           NULL,
        known_vulnerabilities        NVARCHAR(MAX)  NULL,
        minimum_safe_version         NVARCHAR(100)  NULL,
        upgrade_urgency              NVARCHAR(100)  NULL,
        package_location             NVARCHAR(1000) NULL,
        checksum                     NVARCHAR(300)  NULL,
        signature                    NVARCHAR(1000) NULL,
        release_notes                NVARCHAR(MAX)  NULL,
        source_reference             NVARCHAR(500)  NULL,
        verified_date                DATE           NULL,
        reviewer                     NVARCHAR(200)  NULL,
        current_status_id            INT            NOT NULL
            CONSTRAINT fk_pm_asset_fw_release_status REFERENCES grac_practice.entity_status_master(entity_status_id),
        draft_edited_by              NVARCHAR(100)  NULL,
        approved_by                  NVARCHAR(100)  NULL,
        approved_dt                  DATETIME2      NULL,
        entered_by                   NVARCHAR(100)  NOT NULL CONSTRAINT df_pm_asset_fw_release_eby DEFAULT N'system',
        entered_dt                   DATETIME2      NOT NULL CONSTRAINT df_pm_asset_fw_release_edt DEFAULT SYSUTCDATETIME(),
        updated_by                   NVARCHAR(100)  NULL,
        updated_dt                   DATETIME2      NULL,
        record_version               ROWVERSION     NOT NULL,
        CONSTRAINT ck_pm_asset_fw_release_dates CHECK (
            release_date IS NULL OR (
                (engineering_support_end_date IS NULL OR engineering_support_end_date >= release_date) AND
                (standard_support_end_date    IS NULL OR standard_support_end_date    >= release_date) AND
                (security_fix_end_date        IS NULL OR security_fix_end_date        >= release_date) AND
                (end_of_life_date             IS NULL OR end_of_life_date             >= release_date)))
    );
    CREATE INDEX ix_pm_asset_fw_release_product ON grac_practice.asset_firmware_release(product_id);
    PRINT '426: asset_firmware_release created.';
END
GO

IF OBJECT_ID('grac_practice.asset_firmware_compatibility','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_firmware_compatibility (
        compat_id         BIGINT         IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_asset_fw_compat PRIMARY KEY,
        organization_id   BIGINT         NULL
            CONSTRAINT fk_pm_asset_fw_compat_org REFERENCES grac_practice.organization(organization_id),
        release_id        BIGINT         NOT NULL
            CONSTRAINT fk_pm_asset_fw_compat_release REFERENCES grac_practice.asset_firmware_release(release_id),
        asset_type_id     INT            NOT NULL
            CONSTRAINT fk_pm_asset_fw_compat_type REFERENCES grac_practice.dependency_asset_type_master(asset_type_id),
        make_id           INT            NULL
            CONSTRAINT fk_pm_asset_fw_compat_make REFERENCES grac_practice.asset_make(make_id),
        model_id          BIGINT         NULL
            CONSTRAINT fk_pm_asset_fw_compat_model REFERENCES grac_practice.asset_model(model_id),
        hardware_revision NVARCHAR(120)  NULL,
        compat_status     NVARCHAR(30)   NOT NULL
            CONSTRAINT ck_pm_asset_fw_compat_status CHECK (compat_status IN
                (N'CERTIFIED', N'SUPPORTED', N'CONDITIONAL', N'UNSUPPORTED', N'UNKNOWN')),
        upgrade_path      NVARCHAR(1000) NULL,
        effective_from    DATE           NULL,
        effective_to      DATE           NULL,
        evidence          NVARCHAR(1000) NULL,
        reviewer          NVARCHAR(200)  NULL,
        approval_status   NVARCHAR(20)   NOT NULL CONSTRAINT df_pm_asset_fw_compat_approval DEFAULT N'DRAFT'
            CONSTRAINT ck_pm_asset_fw_compat_approval CHECK (approval_status IN (N'DRAFT', N'APPROVED')),
        edited_by         NVARCHAR(100)  NULL,
        approved_by       NVARCHAR(100)  NULL,
        approved_dt       DATETIME2      NULL,
        is_active         BIT            NOT NULL CONSTRAINT df_pm_asset_fw_compat_active DEFAULT 1,
        entered_by        NVARCHAR(100)  NOT NULL CONSTRAINT df_pm_asset_fw_compat_eby DEFAULT N'system',
        entered_dt        DATETIME2      NOT NULL CONSTRAINT df_pm_asset_fw_compat_edt DEFAULT SYSUTCDATETIME(),
        updated_by        NVARCHAR(100)  NULL,
        updated_dt        DATETIME2      NULL,
        record_version    ROWVERSION     NOT NULL,
        CONSTRAINT ck_pm_asset_fw_compat_effective CHECK (effective_to IS NULL OR effective_from IS NULL OR effective_to >= effective_from)
    );
    CREATE INDEX ix_pm_asset_fw_compat_release ON grac_practice.asset_firmware_compatibility(release_id);
    CREATE INDEX ix_pm_asset_fw_compat_model   ON grac_practice.asset_firmware_compatibility(model_id, asset_type_id, make_id);
    PRINT '426: asset_firmware_compatibility created.';
END
GO

-- =====================================================================
-- 2. Release status (state-machine framework) -- the BRD 4.4 list
-- =====================================================================
MERGE grac_practice.entity_status_master AS t
USING (VALUES
    (N'FirmwareRelease', N'DRAFT',       N'Draft',       10, 0, 1, N'Being prepared; not used for compatibility or recommendations.'),
    (N'FirmwareRelease', N'APPROVED',    N'Approved',    20, 0, 0, N'Approved catalogue release.'),
    (N'FirmwareRelease', N'RECOMMENDED', N'Recommended', 30, 0, 0, N'Approved and recommended target.'),
    (N'FirmwareRelease', N'SUPPORTED',   N'Supported',   40, 0, 0, N'Approved and supported.'),
    (N'FirmwareRelease', N'DEPRECATED',  N'Deprecated',  50, 0, 0, N'Still supported; plan an upgrade.'),
    (N'FirmwareRelease', N'EOS',         N'EOS',         60, 0, 0, N'End of support.'),
    (N'FirmwareRelease', N'EOL',         N'EOL',         70, 0, 0, N'End of life.'),
    (N'FirmwareRelease', N'WITHDRAWN',   N'Withdrawn',   80, 0, 0, N'Withdrawn by the publisher or the catalogue; kept for history.')
) AS s(entity_type, status_code, status_name, display_order, is_terminal, is_initial, description)
ON t.entity_type = s.entity_type AND t.status_code = s.status_code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (entity_type, status_code, status_name, display_order, is_terminal, is_initial, description, entered_by)
    VALUES (s.entity_type, s.status_code, s.status_name, s.display_order, s.is_terminal, s.is_initial, s.description, N'seed-426');
PRINT CONCAT('426: FirmwareRelease statuses inserted: ', @@ROWCOUNT);
GO

MERGE grac_practice.entity_state_transition_rule AS t
USING (VALUES
    (CAST(NULL AS NVARCHAR(60)), N'DRAFT', 0, 0, N'Create a release.'),
    (N'DRAFT',       N'APPROVED',    0, 1, N'Approve the release.'),
    (N'DRAFT',       N'WITHDRAWN',   1, 0, N'Discard a draft.'),
    (N'APPROVED',    N'RECOMMENDED', 0, 0, N'Mark as recommended.'),
    (N'APPROVED',    N'SUPPORTED',   0, 0, N'Mark as supported.'),
    (N'APPROVED',    N'DEPRECATED',  0, 0, N'Deprecate.'),
    (N'APPROVED',    N'EOS',         0, 0, N'End of support reached.'),
    (N'APPROVED',    N'EOL',         0, 0, N'End of life reached.'),
    (N'APPROVED',    N'WITHDRAWN',   1, 0, N'Withdraw.'),
    (N'RECOMMENDED', N'SUPPORTED',   0, 0, N'No longer the recommended target.'),
    (N'RECOMMENDED', N'DEPRECATED',  0, 0, N'Deprecate.'),
    (N'RECOMMENDED', N'EOS',         0, 0, N'End of support reached.'),
    (N'RECOMMENDED', N'EOL',         0, 0, N'End of life reached.'),
    (N'RECOMMENDED', N'WITHDRAWN',   1, 0, N'Withdraw.'),
    (N'SUPPORTED',   N'RECOMMENDED', 0, 0, N'Mark as recommended.'),
    (N'SUPPORTED',   N'DEPRECATED',  0, 0, N'Deprecate.'),
    (N'SUPPORTED',   N'EOS',         0, 0, N'End of support reached.'),
    (N'SUPPORTED',   N'EOL',         0, 0, N'End of life reached.'),
    (N'SUPPORTED',   N'WITHDRAWN',   1, 0, N'Withdraw.'),
    (N'DEPRECATED',  N'EOS',         0, 0, N'End of support reached.'),
    (N'DEPRECATED',  N'EOL',         0, 0, N'End of life reached.'),
    (N'DEPRECATED',  N'WITHDRAWN',   1, 0, N'Withdraw.'),
    (N'EOS',         N'EOL',         0, 0, N'End of life reached.'),
    (N'EOS',         N'WITHDRAWN',   1, 0, N'Withdraw.'),
    (N'EOL',         N'WITHDRAWN',   1, 0, N'Withdraw.'),
    (N'WITHDRAWN',   N'DRAFT',       1, 0, N'Reopen a withdrawn release.')
) AS s(from_status_code, to_status_code, requires_reason, requires_approval, description)
ON t.entity_type = N'FirmwareRelease'
   AND ISNULL(t.from_status_code, N'__NULL__') = ISNULL(s.from_status_code, N'__NULL__')
   AND t.to_status_code = s.to_status_code
   AND t.actor_role_code IS NULL
WHEN NOT MATCHED BY TARGET THEN
    INSERT (entity_type, from_status_code, to_status_code, actor_role_code, requires_reason, requires_approval, description, entered_by)
    VALUES (N'FirmwareRelease', s.from_status_code, s.to_status_code, NULL, s.requires_reason, s.requires_approval, s.description, N'seed-426');
PRINT CONCAT('426: FirmwareRelease transition rules inserted: ', @@ROWCOUNT);
GO

-- =====================================================================
-- 3. Readers
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_firmware_list
    @organization_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 54850, 'Organization not found.', 1;

    -- 1. Products
    SELECT p.product_id AS ProductId, CAST(CASE WHEN p.organization_id IS NULL THEN 1 ELSE 0 END AS BIT) AS IsShared,
           p.publisher_make_id AS PublisherMakeId, m.make_name AS PublisherName, p.product_code AS ProductCode,
           p.product_name AS ProductName, p.description AS Description, p.status AS Status,
           CONVERT(BIGINT, p.record_version) AS RecordVersion,
           (SELECT COUNT(*) FROM grac_practice.asset_firmware_release r
             WHERE r.product_id = p.product_id AND (r.organization_id IS NULL OR r.organization_id = @organization_id)) AS ReleaseCount
      FROM grac_practice.asset_firmware_product p
      JOIN grac_practice.asset_make m ON m.make_id = p.publisher_make_id
     WHERE p.organization_id IS NULL OR p.organization_id = @organization_id
     ORDER BY m.make_name, p.product_name;

    -- 2. Releases
    SELECT r.release_id AS ReleaseId, CAST(CASE WHEN r.organization_id IS NULL THEN 1 ELSE 0 END AS BIT) AS IsShared,
           r.product_id AS ProductId, p.product_name AS ProductName, m.make_name AS PublisherName,
           r.release_code AS ReleaseCode, r.version AS Version, r.build AS Build, r.branch_train AS BranchTrain,
           r.edition AS Edition, r.release_date AS ReleaseDate, r.standard_support_end_date AS StandardSupportEndDate,
           r.end_of_life_date AS EndOfLifeDate, r.upgrade_urgency AS UpgradeUrgency,
           s.status_code AS StatusCode, s.status_name AS StatusName,
           (SELECT COUNT(*) FROM grac_practice.asset_firmware_compatibility c
             WHERE c.release_id = r.release_id AND c.is_active = 1
               AND (c.organization_id IS NULL OR c.organization_id = @organization_id)) AS CompatCount,
           (SELECT COUNT(*) FROM grac_practice.asset_firmware_compatibility c
             WHERE c.release_id = r.release_id AND c.is_active = 1 AND c.approval_status = N'APPROVED'
               AND (c.organization_id IS NULL OR c.organization_id = @organization_id)) AS ApprovedCompatCount
      FROM grac_practice.asset_firmware_release r
      JOIN grac_practice.asset_firmware_product p ON p.product_id = r.product_id
      JOIN grac_practice.asset_make m ON m.make_id = p.publisher_make_id
      JOIN grac_practice.entity_status_master s ON s.entity_status_id = r.current_status_id
     WHERE r.organization_id IS NULL OR r.organization_id = @organization_id
     ORDER BY m.make_name, p.product_name, r.version, r.build;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_asset_firmware_release_get
    @organization_id BIGINT,
    @release_id      BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.asset_firmware_release
                    WHERE release_id = @release_id AND (organization_id IS NULL OR organization_id = @organization_id))
        THROW 54857, 'Firmware release not found.', 1;

    -- 1. The release
    SELECT r.release_id AS ReleaseId, CAST(CASE WHEN r.organization_id IS NULL THEN 1 ELSE 0 END AS BIT) AS IsShared,
           r.product_id AS ProductId, p.product_name AS ProductName, p.publisher_make_id AS PublisherMakeId,
           m.make_name AS PublisherName, r.release_code AS ReleaseCode, r.version AS Version, r.build AS Build,
           r.branch_train AS BranchTrain, r.edition AS Edition, r.release_date AS ReleaseDate,
           r.engineering_support_end_date AS EngineeringSupportEndDate, r.standard_support_end_date AS StandardSupportEndDate,
           r.security_fix_end_date AS SecurityFixEndDate, r.end_of_life_date AS EndOfLifeDate,
           r.known_vulnerabilities AS KnownVulnerabilities, r.minimum_safe_version AS MinimumSafeVersion,
           r.upgrade_urgency AS UpgradeUrgency, r.package_location AS PackageLocation, r.checksum AS Checksum,
           r.signature AS Signature, r.release_notes AS ReleaseNotes, r.source_reference AS SourceReference,
           r.verified_date AS VerifiedDate, r.reviewer AS Reviewer, s.status_code AS StatusCode, s.status_name AS StatusName,
           r.draft_edited_by AS DraftEditedBy, r.approved_by AS ApprovedBy, r.approved_dt AS ApprovedDt,
           CONVERT(BIGINT, r.record_version) AS RecordVersion
      FROM grac_practice.asset_firmware_release r
      JOIN grac_practice.asset_firmware_product p ON p.product_id = r.product_id
      JOIN grac_practice.asset_make m ON m.make_id = p.publisher_make_id
      JOIN grac_practice.entity_status_master s ON s.entity_status_id = r.current_status_id
     WHERE r.release_id = @release_id;

    -- 2. Compatibility rows visible to the organization
    SELECT c.compat_id AS CompatId, CAST(CASE WHEN c.organization_id IS NULL THEN 1 ELSE 0 END AS BIT) AS IsShared,
           c.asset_type_id AS AssetTypeId, t.asset_type_name AS AssetTypeName, c.make_id AS MakeId, mk.make_name AS MakeName,
           c.model_id AS ModelId, md.model_name AS ModelName, md.variant AS ModelVariant, c.hardware_revision AS HardwareRevision,
           c.compat_status AS CompatStatus, c.upgrade_path AS UpgradePath, c.effective_from AS EffectiveFrom,
           c.effective_to AS EffectiveTo, c.evidence AS Evidence, c.reviewer AS Reviewer, c.approval_status AS ApprovalStatus,
           c.edited_by AS EditedBy, c.approved_by AS ApprovedBy, c.approved_dt AS ApprovedDt, c.is_active AS IsActive,
           CONVERT(BIGINT, c.record_version) AS RecordVersion
      FROM grac_practice.asset_firmware_compatibility c
      JOIN grac_practice.dependency_asset_type_master t ON t.asset_type_id = c.asset_type_id
      LEFT JOIN grac_practice.asset_make mk ON mk.make_id = c.make_id
      LEFT JOIN grac_practice.asset_model md ON md.model_id = c.model_id
     WHERE c.release_id = @release_id AND (c.organization_id IS NULL OR c.organization_id = @organization_id)
     ORDER BY c.is_active DESC, t.asset_type_name, mk.make_name, md.model_name;

    -- 3. Lifecycle milestone history
    SELECT e.event_id AS EventId, e.milestone_code AS MilestoneCode, e.before_value AS BeforeValue,
           e.after_value AS AfterValue, e.source AS Source, e.reason AS Reason, e.entered_by AS EnteredBy, e.entered_dt AS EnteredDt
      FROM grac_practice.technology_lifecycle_event e
     WHERE e.entity_type = N'FIRMWARE' AND e.entity_id = @release_id
     ORDER BY e.entered_dt DESC, e.event_id DESC;

    -- 4. Status history
    SELECT l.transition_log_id AS TransitionLogId, fs.status_name AS FromStatus, ts.status_name AS ToStatus,
           l.actor_employee_id AS ActorEmployeeId, emp.employee_name AS ActorName,
           l.reason_code AS ReasonCode, l.reason_text AS ReasonText, l.transitioned_at AS TransitionedAt
      FROM grac_practice.entity_state_transition_log l
      LEFT JOIN grac_practice.entity_status_master fs ON fs.entity_status_id = l.from_status_id
      JOIN grac_practice.entity_status_master ts ON ts.entity_status_id = l.to_status_id
      LEFT JOIN grac_practice.organization_employee emp ON emp.employee_id = l.actor_employee_id
     WHERE l.entity_type = N'FirmwareRelease' AND l.entity_id = @release_id
     ORDER BY l.transitioned_at DESC, l.transition_log_id DESC;
END
GO

-- Approved, in-effect compatibility for one model (4.8). A row matches
-- when it names the model, or names the model's make with no model, or
-- names neither; the asset type must always match. HardwareRevisionMatch
-- is 1 when the row has no revision or the same one as the model.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_model_firmware_list
    @organization_id BIGINT,
    @model_id        BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @make_id INT, @type_id INT, @hw NVARCHAR(120), @found BIT = 0,
            @today DATE = CAST(SYSUTCDATETIME() AS DATE);
    SELECT @found = 1, @make_id = make_id, @type_id = asset_type_id, @hw = hardware_revision
      FROM grac_practice.asset_model
     WHERE model_id = @model_id AND (organization_id IS NULL OR organization_id = @organization_id);
    IF @found = 0 THROW 54807, 'Model not found.', 1;

    SELECT c.compat_id AS CompatId, r.release_id AS ReleaseId, p.product_name AS ProductName, mk.make_name AS PublisherName,
           r.version AS Version, r.build AS Build, r.edition AS Edition, s.status_code AS ReleaseStatusCode,
           s.status_name AS ReleaseStatusName, c.compat_status AS CompatStatus, c.hardware_revision AS HardwareRevision,
           CAST(CASE WHEN c.hardware_revision IS NULL OR c.hardware_revision = ISNULL(@hw, N'') THEN 1 ELSE 0 END AS BIT) AS HardwareRevisionMatch,
           CASE WHEN c.model_id IS NOT NULL THEN N'MODEL' WHEN c.make_id IS NOT NULL THEN N'MAKE' ELSE N'ASSET_TYPE' END AS MatchLevel,
           c.upgrade_path AS UpgradePath, r.end_of_life_date AS EndOfLifeDate
      FROM grac_practice.asset_firmware_compatibility c
      JOIN grac_practice.asset_firmware_release r ON r.release_id = c.release_id
      JOIN grac_practice.asset_firmware_product p ON p.product_id = r.product_id
      JOIN grac_practice.asset_make mk ON mk.make_id = p.publisher_make_id
      JOIN grac_practice.entity_status_master s ON s.entity_status_id = r.current_status_id
     WHERE c.is_active = 1 AND c.approval_status = N'APPROVED'
       AND (c.organization_id IS NULL OR c.organization_id = @organization_id)
       AND (r.organization_id IS NULL OR r.organization_id = @organization_id)
       AND s.status_code NOT IN (N'DRAFT', N'WITHDRAWN')
       AND c.asset_type_id = @type_id
       AND (c.model_id = @model_id OR (c.model_id IS NULL AND (c.make_id = @make_id OR c.make_id IS NULL)))
       AND (c.effective_from IS NULL OR c.effective_from <= @today)
       AND (c.effective_to   IS NULL OR c.effective_to   >= @today)
     ORDER BY CASE c.model_id WHEN @model_id THEN 0 ELSE 1 END, p.product_name, r.version DESC;
END
GO

-- =====================================================================
-- 4. Writers (scope parameters as in 425)
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_firmware_product_save
    @organization_id         BIGINT,
    @shared                  BIT            = 0,
    @product_id              INT            = NULL,
    @publisher_make_id       INT,
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
    SET @product_name = NULLIF(LTRIM(RTRIM(@product_name)), N'');
    SET @status = CASE WHEN @status = N'Inactive' THEN N'Inactive' ELSE N'Active' END;

    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 54850, 'Organization not found.', 1;
    DECLARE @scope_org BIGINT = CASE WHEN @shared = 1 THEN NULL ELSE @organization_id END;
    DECLARE @found BIT = 0, @row_org BIGINT, @rv BIGINT, @old_make INT, @before NVARCHAR(MAX);
    IF @product_id IS NOT NULL
    BEGIN
        SELECT @found = 1, @row_org = organization_id, @rv = CONVERT(BIGINT, record_version), @old_make = publisher_make_id
          FROM grac_practice.asset_firmware_product WHERE product_id = @product_id;
        IF @found = 0 OR (@row_org IS NOT NULL AND @row_org <> @organization_id)
            THROW 54851, 'Firmware product not found.', 1;
        IF ISNULL(@row_org, -1) <> ISNULL(@scope_org, -1)
            THROW 54854, 'This entry belongs to the shared catalogue; only the platform administrator can change it.', 1;
        IF @expected_record_version IS NOT NULL AND @expected_record_version <> @rv
            THROW 54855, 'This entry was changed by someone else. Reload and try again.', 1;
    END
    IF @product_name IS NULL THROW 54852, 'The firmware product name is required.', 1;
    DECLARE @make_org BIGINT, @make_status NVARCHAR(30), @make_found BIT = 0;
    SELECT @make_found = 1, @make_org = organization_id, @make_status = status FROM grac_practice.asset_make WHERE make_id = @publisher_make_id;
    IF @make_found = 0 OR (@make_org IS NOT NULL AND @make_org <> @organization_id)
       OR (@scope_org IS NULL AND @make_org IS NOT NULL)
       OR (@make_status <> N'Active' AND ISNULL(@old_make, -1) <> @publisher_make_id)
        THROW 54856, 'Select an active publisher (make) from the catalogue; a shared product needs a shared make.', 1;
    IF @product_id IS NOT NULL AND @old_make <> @publisher_make_id
       AND EXISTS (SELECT 1 FROM grac_practice.asset_firmware_release WHERE product_id = @product_id)
        THROW 54856, 'The product already has releases, so its publisher cannot change.', 1;
    IF EXISTS (SELECT 1 FROM grac_practice.asset_firmware_product
                WHERE publisher_make_id = @publisher_make_id AND product_name = @product_name
                  AND product_id <> ISNULL(@product_id, -1)
                  AND (organization_id IS NULL OR organization_id = @organization_id))
        THROW 54853, 'This publisher already has a firmware product with that name.', 1;

    SET @before = (SELECT publisher_make_id AS publisherMakeId, product_name AS productName, description, status
                     FROM grac_practice.asset_firmware_product WHERE product_id = @product_id FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
    BEGIN TRAN;
    IF @product_id IS NULL
    BEGIN
        DECLARE @make_name NVARCHAR(200);
        SELECT @make_name = make_name FROM grac_practice.asset_make WHERE make_id = @publisher_make_id;
        DECLARE @base NVARCHAR(160) = N'FW_' + ISNULL(grac_practice.fn_asset_make_code(CONCAT(@make_name, N' ', @product_name), 80), N'X'),
                @code NVARCHAR(160), @n INT = 1;
        SET @code = @base;
        WHILE EXISTS (SELECT 1 FROM grac_practice.asset_firmware_product WHERE product_code = @code)
        BEGIN
            SET @n = @n + 1;
            SET @code = @base + N'_' + CAST(@n AS NVARCHAR(10));
        END
        INSERT grac_practice.asset_firmware_product (organization_id, publisher_make_id, product_code, product_name, description, status, entered_by)
        VALUES (@scope_org, @publisher_make_id, @code, @product_name, NULLIF(LTRIM(RTRIM(@description)), N''), @status, @actor);
        SET @out_product_id = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        UPDATE grac_practice.asset_firmware_product
           SET publisher_make_id = @publisher_make_id, product_name = @product_name,
               description = NULLIF(LTRIM(RTRIM(@description)), N''), status = @status,
               updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE product_id = @product_id;
        SET @out_product_id = @product_id;
    END
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-firmware-product', @out_product_id, CASE WHEN @product_id IS NULL THEN N'ADD' ELSE N'SAVE' END, @before,
            (SELECT @scope_org AS organizationId, @publisher_make_id AS publisherMakeId, @product_name AS productName,
                    @description AS description, @status AS status FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            N'Active', @actor);
    COMMIT;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_asset_firmware_release_save
    @organization_id              BIGINT,
    @shared                       BIT            = 0,
    @release_id                   BIGINT         = NULL,
    @product_id                   INT,
    @version                      NVARCHAR(100),
    @build                        NVARCHAR(100)  = NULL,
    @branch_train                 NVARCHAR(100)  = NULL,
    @edition                      NVARCHAR(100)  = NULL,
    @release_date                 DATE           = NULL,
    @engineering_support_end_date DATE           = NULL,
    @standard_support_end_date    DATE           = NULL,
    @security_fix_end_date        DATE           = NULL,
    @end_of_life_date             DATE           = NULL,
    @known_vulnerabilities        NVARCHAR(MAX)  = NULL,
    @minimum_safe_version         NVARCHAR(100)  = NULL,
    @upgrade_urgency              NVARCHAR(100)  = NULL,
    @package_location             NVARCHAR(1000) = NULL,
    @checksum                     NVARCHAR(300)  = NULL,
    @signature                    NVARCHAR(1000) = NULL,
    @release_notes                NVARCHAR(MAX)  = NULL,
    @source_reference             NVARCHAR(500)  = NULL,
    @verified_date                DATE           = NULL,
    @reviewer                     NVARCHAR(200)  = NULL,
    @change_reason                NVARCHAR(1000) = NULL,
    @expected_record_version      BIGINT         = NULL,
    @actor_employee_id            BIGINT         = NULL,
    @actor                        NVARCHAR(100)  = N'system',
    @out_release_id               BIGINT         = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    SET @shared = ISNULL(@shared, 0);
    SET @version = NULLIF(LTRIM(RTRIM(@version)), N'');
    SET @build = NULLIF(LTRIM(RTRIM(@build)), N'');
    SET @branch_train = NULLIF(LTRIM(RTRIM(@branch_train)), N'');
    SET @edition = NULLIF(LTRIM(RTRIM(@edition)), N'');
    SET @source_reference = NULLIF(LTRIM(RTRIM(@source_reference)), N'');
    SET @change_reason = NULLIF(LTRIM(RTRIM(@change_reason)), N'');

    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 54850, 'Organization not found.', 1;
    DECLARE @scope_org BIGINT = CASE WHEN @shared = 1 THEN NULL ELSE @organization_id END;

    DECLARE @old TABLE (organization_id BIGINT, product_id INT, version NVARCHAR(100), build NVARCHAR(100),
        branch_train NVARCHAR(100), edition NVARCHAR(100), release_date DATE, engineering_support_end_date DATE,
        standard_support_end_date DATE, security_fix_end_date DATE, end_of_life_date DATE, status_code NVARCHAR(60), rv BIGINT);
    DECLARE @found BIT = 0, @row_org BIGINT, @status_code NVARCHAR(60), @rv BIGINT, @before NVARCHAR(MAX);
    IF @release_id IS NOT NULL
    BEGIN
        INSERT @old
        SELECT r.organization_id, r.product_id, r.version, r.build, r.branch_train, r.edition, r.release_date,
               r.engineering_support_end_date, r.standard_support_end_date, r.security_fix_end_date, r.end_of_life_date,
               s.status_code, CONVERT(BIGINT, r.record_version)
          FROM grac_practice.asset_firmware_release r
          JOIN grac_practice.entity_status_master s ON s.entity_status_id = r.current_status_id
         WHERE r.release_id = @release_id;
        SELECT @found = 1, @row_org = organization_id, @status_code = status_code, @rv = rv FROM @old;
        IF @found = 0 OR (@row_org IS NOT NULL AND @row_org <> @organization_id)
            THROW 54857, 'Firmware release not found.', 1;
        IF ISNULL(@row_org, -1) <> ISNULL(@scope_org, -1)
            THROW 54854, 'This entry belongs to the shared catalogue; only the platform administrator can change it.', 1;
        IF @expected_record_version IS NOT NULL AND @expected_record_version <> @rv
            THROW 54855, 'This entry was changed by someone else. Reload and try again.', 1;
        IF @status_code <> N'DRAFT' AND EXISTS (
            SELECT 1 FROM @old o
             WHERE o.product_id <> @product_id OR o.version <> ISNULL(@version, N'')
                OR ISNULL(o.build, N'') <> ISNULL(@build, N'') OR ISNULL(o.branch_train, N'') <> ISNULL(@branch_train, N'')
                OR ISNULL(o.edition, N'') <> ISNULL(@edition, N''))
            THROW 54862, 'The release has been approved: product, version, build, branch and edition can no longer change.', 1;
    END
    IF @version IS NULL THROW 54858, 'The firmware version is required.', 1;

    DECLARE @prod_org BIGINT, @prod_status NVARCHAR(30), @prod_found BIT = 0;
    SELECT @prod_found = 1, @prod_org = organization_id, @prod_status = status FROM grac_practice.asset_firmware_product WHERE product_id = @product_id;
    IF @prod_found = 0 OR (@prod_org IS NOT NULL AND @prod_org <> @organization_id)
        THROW 54851, 'Firmware product not found.', 1;
    IF (@scope_org IS NULL AND @prod_org IS NOT NULL)
       OR (@prod_status <> N'Active' AND NOT EXISTS (SELECT 1 FROM @old WHERE product_id = @product_id))
        THROW 54851, 'Select an active firmware product; a shared release needs a shared product.', 1;
    IF @release_date IS NOT NULL AND (
          @engineering_support_end_date < @release_date OR @standard_support_end_date < @release_date
       OR @security_fix_end_date        < @release_date OR @end_of_life_date          < @release_date)
        THROW 54860, 'Support-end and end-of-life dates cannot precede the release date.', 1;
    IF EXISTS (SELECT 1 FROM grac_practice.asset_firmware_release r
                WHERE r.product_id = @product_id AND r.release_id <> ISNULL(@release_id, -1)
                  AND (r.organization_id IS NULL OR r.organization_id = @organization_id)
                  AND r.version = @version AND ISNULL(r.build, N'') = ISNULL(@build, N'')
                  AND ISNULL(r.branch_train, N'') = ISNULL(@branch_train, N'') AND ISNULL(r.edition, N'') = ISNULL(@edition, N''))
        THROW 54859, 'This product already has a release with the same version, build, branch and edition.', 1;

    DECLARE @changes TABLE (milestone_code NVARCHAR(60), before_value NVARCHAR(200), after_value NVARCHAR(200));
    IF @release_id IS NOT NULL
    BEGIN
        INSERT @changes (milestone_code, before_value, after_value)
        SELECT v.code, v.b, v.a
          FROM @old o
         CROSS APPLY (VALUES
            (N'RELEASE_DATE',             CONVERT(NVARCHAR(10), o.release_date, 23),                 CONVERT(NVARCHAR(10), @release_date, 23)),
            (N'END_ENGINEERING_SUPPORT',  CONVERT(NVARCHAR(10), o.engineering_support_end_date, 23), CONVERT(NVARCHAR(10), @engineering_support_end_date, 23)),
            (N'END_STANDARD_SUPPORT',     CONVERT(NVARCHAR(10), o.standard_support_end_date, 23),    CONVERT(NVARCHAR(10), @standard_support_end_date, 23)),
            (N'END_SECURITY_FIX',         CONVERT(NVARCHAR(10), o.security_fix_end_date, 23),        CONVERT(NVARCHAR(10), @security_fix_end_date, 23)),
            (N'END_OF_LIFE_DATE',         CONVERT(NVARCHAR(10), o.end_of_life_date, 23),             CONVERT(NVARCHAR(10), @end_of_life_date, 23))
         ) AS v(code, b, a)
         WHERE ISNULL(v.b, N'') <> ISNULL(v.a, N'');
        IF @change_reason IS NULL AND EXISTS (SELECT 1 FROM @changes WHERE before_value IS NOT NULL)
            THROW 54861, 'A reason is required to change a lifecycle date that already had a value.', 1;
    END

    SET @before = (SELECT product_id AS productId, version, build, branch_train AS branchTrain, edition,
                          release_date AS releaseDate, engineering_support_end_date AS engineeringSupportEndDate,
                          standard_support_end_date AS standardSupportEndDate, security_fix_end_date AS securityFixEndDate,
                          end_of_life_date AS endOfLifeDate, minimum_safe_version AS minimumSafeVersion,
                          upgrade_urgency AS upgradeUrgency, source_reference AS sourceReference
                     FROM grac_practice.asset_firmware_release WHERE release_id = @release_id FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    DECLARE @draft_id INT = grac_practice.fn_get_entity_status_id(N'FirmwareRelease', N'DRAFT');
    DECLARE @to_status_id INT, @log_id BIGINT;

    BEGIN TRAN;
    IF @release_id IS NULL
    BEGIN
        DECLARE @product_code NVARCHAR(100);
        SELECT @product_code = product_code FROM grac_practice.asset_firmware_product WHERE product_id = @product_id;
        DECLARE @base NVARCHAR(160) = LEFT(@product_code, 80) + N'_' + ISNULL(grac_practice.fn_asset_make_code(
                    CONCAT(@version, N' ', @build, N' ', @branch_train, N' ', @edition), 50), N'X'),
                @code NVARCHAR(160), @n INT = 1;
        SET @code = @base;
        WHILE EXISTS (SELECT 1 FROM grac_practice.asset_firmware_release WHERE release_code = @code)
        BEGIN
            SET @n = @n + 1;
            SET @code = @base + N'_' + CAST(@n AS NVARCHAR(10));
        END
        INSERT grac_practice.asset_firmware_release
            (organization_id, product_id, release_code, version, build, branch_train, edition, release_date,
             engineering_support_end_date, standard_support_end_date, security_fix_end_date, end_of_life_date,
             known_vulnerabilities, minimum_safe_version, upgrade_urgency, package_location, checksum, signature,
             release_notes, source_reference, verified_date, reviewer, current_status_id, draft_edited_by, entered_by)
        VALUES (@scope_org, @product_id, @code, @version, @build, @branch_train, @edition, @release_date,
                @engineering_support_end_date, @standard_support_end_date, @security_fix_end_date, @end_of_life_date,
                NULLIF(LTRIM(RTRIM(@known_vulnerabilities)), N''), NULLIF(LTRIM(RTRIM(@minimum_safe_version)), N''),
                NULLIF(LTRIM(RTRIM(@upgrade_urgency)), N''), NULLIF(LTRIM(RTRIM(@package_location)), N''),
                NULLIF(LTRIM(RTRIM(@checksum)), N''), NULLIF(LTRIM(RTRIM(@signature)), N''),
                NULLIF(LTRIM(RTRIM(@release_notes)), N''), @source_reference, @verified_date,
                NULLIF(LTRIM(RTRIM(@reviewer)), N''), @draft_id, @actor, @actor);
        SET @out_release_id = SCOPE_IDENTITY();
        EXEC grac_practice.sp_pm_state_transition
             @entity_type = N'FirmwareRelease', @entity_id = @out_release_id,
             @from_status_code = NULL, @to_status_code = N'DRAFT',
             @actor_employee_id = @actor_employee_id, @actor_role_code = NULL,
             @reason_code = N'CREATED', @reason_text = NULL,
             @to_status_id = @to_status_id OUTPUT, @transition_log_id = @log_id OUTPUT;
    END
    ELSE
    BEGIN
        UPDATE grac_practice.asset_firmware_release
           SET product_id = @product_id, version = @version, build = @build, branch_train = @branch_train, edition = @edition,
               release_date = @release_date, engineering_support_end_date = @engineering_support_end_date,
               standard_support_end_date = @standard_support_end_date, security_fix_end_date = @security_fix_end_date,
               end_of_life_date = @end_of_life_date, known_vulnerabilities = NULLIF(LTRIM(RTRIM(@known_vulnerabilities)), N''),
               minimum_safe_version = NULLIF(LTRIM(RTRIM(@minimum_safe_version)), N''),
               upgrade_urgency = NULLIF(LTRIM(RTRIM(@upgrade_urgency)), N''),
               package_location = NULLIF(LTRIM(RTRIM(@package_location)), N''), checksum = NULLIF(LTRIM(RTRIM(@checksum)), N''),
               signature = NULLIF(LTRIM(RTRIM(@signature)), N''), release_notes = NULLIF(LTRIM(RTRIM(@release_notes)), N''),
               source_reference = @source_reference, verified_date = @verified_date, reviewer = NULLIF(LTRIM(RTRIM(@reviewer)), N''),
               draft_edited_by = CASE WHEN @status_code = N'DRAFT' THEN @actor ELSE draft_edited_by END,
               updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE release_id = @release_id;
        SET @out_release_id = @release_id;
        INSERT grac_practice.technology_lifecycle_event
            (entity_type, entity_id, milestone_code, before_value, after_value, source, reason, impact_count, entered_by)
        SELECT N'FIRMWARE', @release_id, milestone_code, before_value, after_value, @source_reference, @change_reason, NULL, @actor
          FROM @changes;
    END
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-firmware-release', @out_release_id, CASE WHEN @release_id IS NULL THEN N'ADD' ELSE N'SAVE' END, @before,
            (SELECT @scope_org AS organizationId, @product_id AS productId, @version AS version, @build AS build,
                    @branch_train AS branchTrain, @edition AS edition, @release_date AS releaseDate,
                    @engineering_support_end_date AS engineeringSupportEndDate, @standard_support_end_date AS standardSupportEndDate,
                    @security_fix_end_date AS securityFixEndDate, @end_of_life_date AS endOfLifeDate,
                    @minimum_safe_version AS minimumSafeVersion, @upgrade_urgency AS upgradeUrgency,
                    @source_reference AS sourceReference, @change_reason AS changeReason FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            N'Active', @actor);
    COMMIT;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_asset_firmware_release_transition
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
      FROM grac_practice.asset_firmware_release r
      JOIN grac_practice.entity_status_master s ON s.entity_status_id = r.current_status_id
      JOIN grac_practice.asset_firmware_product p ON p.product_id = r.product_id
     WHERE r.release_id = @release_id;
    IF @found = 0 OR (@row_org IS NOT NULL AND @row_org <> @organization_id)
        THROW 54857, 'Firmware release not found.', 1;
    IF ISNULL(@row_org, -1) <> CASE WHEN @shared = 1 THEN -1 ELSE @organization_id END
        THROW 54854, 'This entry belongs to the shared catalogue; only the platform administrator can change it.', 1;
    IF @expected_record_version IS NOT NULL AND @expected_record_version <> @rv
        THROW 54855, 'This entry was changed by someone else. Reload and try again.', 1;
    IF @to_status_code IN (N'WITHDRAWN', N'DRAFT') AND @reason_text IS NULL
        THROW 54865, 'A reason is required to withdraw or reopen a release.', 1;
    IF @from = N'DRAFT' AND @to_status_code = N'APPROVED'
    BEGIN
        IF @source IS NULL
            THROW 54863, 'Add the source reference (vendor advisory, release notes or matrix) before approving.', 1;
        IF @prod_status <> N'Active'
            THROW 54863, 'The firmware product is inactive. Reactivate it before approving.', 1;
        IF @editor = @actor
            THROW 54864, 'Segregation of duties: the person who last edited this draft cannot approve it.', 1;
    END

    DECLARE @reason_code NVARCHAR(60) = CASE
        WHEN @to_status_code = N'APPROVED' THEN N'APPROVED' WHEN @to_status_code = N'WITHDRAWN' THEN N'WITHDRAWN'
        WHEN @to_status_code = N'DRAFT' THEN N'REOPENED' ELSE N'STATUS_CHANGED' END;
    DECLARE @to_status_id INT, @log_id BIGINT;

    BEGIN TRAN;
    EXEC grac_practice.sp_pm_state_transition
         @entity_type = N'FirmwareRelease', @entity_id = @release_id,
         @from_status_code = @from, @to_status_code = @to_status_code,
         @actor_employee_id = @actor_employee_id, @actor_role_code = NULL,
         @reason_code = @reason_code, @reason_text = @reason_text,
         @to_status_id = @to_status_id OUTPUT, @transition_log_id = @log_id OUTPUT;
    UPDATE grac_practice.asset_firmware_release
       SET current_status_id = @to_status_id,
           approved_by = CASE WHEN @to_status_code = N'APPROVED' THEN @actor WHEN @to_status_code = N'DRAFT' THEN NULL ELSE approved_by END,
           approved_dt = CASE WHEN @to_status_code = N'APPROVED' THEN SYSUTCDATETIME() WHEN @to_status_code = N'DRAFT' THEN NULL ELSE approved_dt END,
           draft_edited_by = CASE WHEN @to_status_code = N'DRAFT' THEN @actor ELSE draft_edited_by END,
           updated_by = @actor, updated_dt = SYSUTCDATETIME()
     WHERE release_id = @release_id;
    COMMIT;

    SELECT @release_id AS ReleaseId, @to_status_code AS StatusCode;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_asset_firmware_compat_save
    @organization_id         BIGINT,
    @shared                  BIT            = 0,
    @compat_id               BIGINT         = NULL,
    @release_id              BIGINT,
    @asset_type_id           INT,
    @make_id                 INT            = NULL,
    @model_id                BIGINT         = NULL,
    @hardware_revision       NVARCHAR(120)  = NULL,
    @compat_status           NVARCHAR(30),
    @upgrade_path            NVARCHAR(1000) = NULL,
    @effective_from          DATE           = NULL,
    @effective_to            DATE           = NULL,
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
    SET @hardware_revision = NULLIF(LTRIM(RTRIM(@hardware_revision)), N'');
    SET @compat_status = UPPER(LTRIM(RTRIM(ISNULL(@compat_status, N''))));

    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 54850, 'Organization not found.', 1;
    DECLARE @scope_org BIGINT = CASE WHEN @shared = 1 THEN NULL ELSE @organization_id END;
    DECLARE @found BIT = 0, @row_org BIGINT, @rv BIGINT, @before NVARCHAR(MAX), @old_release BIGINT;
    IF @compat_id IS NOT NULL
    BEGIN
        SELECT @found = 1, @row_org = organization_id, @rv = CONVERT(BIGINT, record_version), @old_release = release_id
          FROM grac_practice.asset_firmware_compatibility WHERE compat_id = @compat_id;
        IF @found = 0 OR (@row_org IS NOT NULL AND @row_org <> @organization_id)
            THROW 54866, 'Compatibility record not found.', 1;
        IF ISNULL(@row_org, -1) <> ISNULL(@scope_org, -1)
            THROW 54854, 'This entry belongs to the shared catalogue; only the platform administrator can change it.', 1;
        IF @expected_record_version IS NOT NULL AND @expected_record_version <> @rv
            THROW 54855, 'This entry was changed by someone else. Reload and try again.', 1;
        IF @old_release <> @release_id THROW 54866, 'A compatibility record cannot move to another release.', 1;
    END

    -- Release visible; a shared row needs a shared release.
    DECLARE @rel_org BIGINT, @rel_found BIT = 0;
    SELECT @rel_found = 1, @rel_org = organization_id FROM grac_practice.asset_firmware_release WHERE release_id = @release_id;
    IF @rel_found = 0 OR (@rel_org IS NOT NULL AND @rel_org <> @organization_id) OR (@scope_org IS NULL AND @rel_org IS NOT NULL)
        THROW 54857, 'Firmware release not found (a shared compatibility record needs a shared release).', 1;
    IF @compat_status NOT IN (N'CERTIFIED', N'SUPPORTED', N'CONDITIONAL', N'UNSUPPORTED', N'UNKNOWN')
        THROW 54869, 'Status must be Certified, Supported, Conditional, Unsupported or Unknown.', 1;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.dependency_asset_type_master WHERE asset_type_id = @asset_type_id)
        THROW 54867, 'Select a valid asset type.', 1;
    IF @effective_from IS NOT NULL AND @effective_to IS NOT NULL AND @effective_to < @effective_from
        THROW 54871, 'Effective To cannot be before Effective From.', 1;

    -- Make / model must exist, be visible to this scope and agree with each other and the asset type.
    IF @make_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM grac_practice.asset_make WHERE make_id = @make_id
           AND (organization_id IS NULL OR (@scope_org IS NOT NULL AND organization_id = @organization_id)))
        THROW 54868, 'The make is not in the catalogue for this scope.', 1;
    IF @model_id IS NOT NULL
    BEGIN
        DECLARE @m_make INT, @m_type INT, @m_found BIT = 0;
        SELECT @m_found = 1, @m_make = make_id, @m_type = asset_type_id FROM grac_practice.asset_model
         WHERE model_id = @model_id AND (organization_id IS NULL OR (@scope_org IS NOT NULL AND organization_id = @organization_id));
        IF @m_found = 0 THROW 54868, 'The model is not in the catalogue for this scope.', 1;
        IF @m_type <> @asset_type_id OR (@make_id IS NOT NULL AND @make_id <> @m_make)
            THROW 54868, 'The model belongs to a different make or asset type.', 1;
        SET @make_id = @m_make;
    END

    IF @is_active = 1 AND EXISTS (
        SELECT 1 FROM grac_practice.asset_firmware_compatibility c
         WHERE c.release_id = @release_id AND c.is_active = 1 AND c.compat_id <> ISNULL(@compat_id, -1)
           AND (c.organization_id IS NULL OR c.organization_id = @organization_id)
           AND c.asset_type_id = @asset_type_id AND ISNULL(c.make_id, -1) = ISNULL(@make_id, -1)
           AND ISNULL(c.model_id, -1) = ISNULL(@model_id, -1)
           AND ISNULL(c.hardware_revision, N'') = ISNULL(@hardware_revision, N''))
        THROW 54870, 'An active compatibility record already exists for this release, asset type, make, model and hardware revision.', 1;

    SET @before = (SELECT asset_type_id AS assetTypeId, make_id AS makeId, model_id AS modelId, hardware_revision AS hardwareRevision,
                          compat_status AS compatStatus, upgrade_path AS upgradePath, effective_from AS effectiveFrom,
                          effective_to AS effectiveTo, evidence, reviewer, approval_status AS approvalStatus, is_active AS isActive
                     FROM grac_practice.asset_firmware_compatibility WHERE compat_id = @compat_id FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
    BEGIN TRAN;
    IF @compat_id IS NULL
    BEGIN
        INSERT grac_practice.asset_firmware_compatibility
            (organization_id, release_id, asset_type_id, make_id, model_id, hardware_revision, compat_status, upgrade_path,
             effective_from, effective_to, evidence, reviewer, approval_status, edited_by, is_active, entered_by)
        VALUES (@scope_org, @release_id, @asset_type_id, @make_id, @model_id, @hardware_revision, @compat_status,
                NULLIF(LTRIM(RTRIM(@upgrade_path)), N''), @effective_from, @effective_to, NULLIF(LTRIM(RTRIM(@evidence)), N''),
                NULLIF(LTRIM(RTRIM(@reviewer)), N''), N'DRAFT', @actor, @is_active, @actor);
        SET @out_compat_id = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        -- Any change returns an approved row to Draft: approval covers exactly what was approved.
        UPDATE grac_practice.asset_firmware_compatibility
           SET asset_type_id = @asset_type_id, make_id = @make_id, model_id = @model_id, hardware_revision = @hardware_revision,
               compat_status = @compat_status, upgrade_path = NULLIF(LTRIM(RTRIM(@upgrade_path)), N''),
               effective_from = @effective_from, effective_to = @effective_to, evidence = NULLIF(LTRIM(RTRIM(@evidence)), N''),
               reviewer = NULLIF(LTRIM(RTRIM(@reviewer)), N''), is_active = @is_active,
               approval_status = N'DRAFT', approved_by = NULL, approved_dt = NULL, edited_by = @actor,
               updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE compat_id = @compat_id;
        SET @out_compat_id = @compat_id;
    END
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-firmware-compat', @out_compat_id, CASE WHEN @compat_id IS NULL THEN N'ADD' ELSE N'SAVE' END, @before,
            (SELECT @scope_org AS organizationId, @release_id AS releaseId, @asset_type_id AS assetTypeId, @make_id AS makeId,
                    @model_id AS modelId, @hardware_revision AS hardwareRevision, @compat_status AS compatStatus,
                    @upgrade_path AS upgradePath, @effective_from AS effectiveFrom, @effective_to AS effectiveTo,
                    @evidence AS evidence, @reviewer AS reviewer, @is_active AS isActive FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            N'Active', @actor);
    COMMIT;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_asset_firmware_compat_approve
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
      FROM grac_practice.asset_firmware_compatibility c
      JOIN grac_practice.asset_firmware_release r ON r.release_id = c.release_id
      JOIN grac_practice.entity_status_master s ON s.entity_status_id = r.current_status_id
     WHERE c.compat_id = @compat_id;
    IF @found = 0 OR (@row_org IS NOT NULL AND @row_org <> @organization_id)
        THROW 54866, 'Compatibility record not found.', 1;
    IF ISNULL(@row_org, -1) <> CASE WHEN @shared = 1 THEN -1 ELSE @organization_id END
        THROW 54854, 'This entry belongs to the shared catalogue; only the platform administrator can change it.', 1;
    IF @expected_record_version IS NOT NULL AND @expected_record_version <> @rv
        THROW 54855, 'This entry was changed by someone else. Reload and try again.', 1;
    IF @approval = N'APPROVED' THROW 54872, 'This compatibility record is already approved.', 1;
    IF @active = 0 THROW 54872, 'Reactivate the record before approving it.', 1;
    IF @evidence IS NULL THROW 54872, 'Add the evidence (vendor matrix, release notes, test or internal approval) before approving.', 1;
    IF @rel_status IN (N'DRAFT', N'WITHDRAWN') THROW 54872, 'Approve the firmware release first; a draft or withdrawn release cannot carry approved compatibility.', 1;
    IF @editor = @actor THROW 54864, 'Segregation of duties: the person who last edited this record cannot approve it.', 1;

    BEGIN TRAN;
    UPDATE grac_practice.asset_firmware_compatibility
       SET approval_status = N'APPROVED', approved_by = @actor, approved_dt = SYSUTCDATETIME(),
           updated_by = @actor, updated_dt = SYSUTCDATETIME()
     WHERE compat_id = @compat_id;
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-firmware-compat', @compat_id, N'APPROVE', N'{"approvalStatus":"DRAFT"}', N'{"approvalStatus":"APPROVED"}', N'Active', @actor);
    COMMIT;
END
GO
PRINT '426: firmware procedures created.';
GO

-- =====================================================================
-- Verification
-- =====================================================================
SELECT '426-a tables present' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.asset_firmware_product','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.asset_firmware_release','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.asset_firmware_compatibility','U') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '426-b FirmwareRelease lifecycle (8 statuses, 26 rules)',
       CASE WHEN (SELECT COUNT(*) FROM grac_practice.entity_status_master WHERE entity_type = N'FirmwareRelease') = 8
             AND (SELECT COUNT(*) FROM grac_practice.entity_state_transition_rule WHERE entity_type = N'FirmwareRelease') = 26
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '426-c procedures present',
       CASE WHEN (SELECT COUNT(*) FROM sys.procedures WHERE SCHEMA_NAME(schema_id) = 'grac_practice'
                   AND name IN ('sp_asset_firmware_list', 'sp_asset_firmware_release_get', 'sp_asset_model_firmware_list',
                                'sp_asset_firmware_product_save', 'sp_asset_firmware_release_save',
                                'sp_asset_firmware_release_transition', 'sp_asset_firmware_compat_save',
                                'sp_asset_firmware_compat_approve')) = 8 THEN 'PASS' ELSE 'FAIL' END;
GO

-- =====================================================================
-- UAT (after deploying the API + Web build)
--   1. Technology Catalogue -> Firmware -> Add Product: publisher = a
--      make from 425, name "FortiOS". A second product with the same
--      publisher and name is refused (54853).
--   2. Add Release: version 7.4.3; release 2024-02-01, standard support
--      end 2024-01-01 -- refused (54860). Fix and save (Draft).
--   3. Approve as the same user who saved it -- refused (54864); without
--      a source reference -- refused (54863); as another admin with a
--      source -- Approved. Then mark it Recommended.
--   4. Change the version of the approved release -- refused (54862);
--      change end of life without a reason -- refused (54861); with a
--      reason -- saved and shown in History.
--   5. Compatibility tab: add a row for the asset type and the 425 model
--      (status Certified). Approve without evidence -- refused (54872);
--      add evidence, approve as another user -- Approved. Edit it --
--      it returns to Draft.
--   6. Models -> open the model -> Firmware: the approved, in-effect
--      release is listed with its status and the hardware revision match.
-- =====================================================================
