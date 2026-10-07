-- =====================================================================
-- 430  Installed technology -- firmware / OS history, recommended
--      targets, technology status and technology exceptions
--      (Asset & Contract Management, Phase 4 increment 3)
--
-- REQUEST
-- -------
--   BRD v1.7 4.6 "Installed Technology History" (AssetFirmwareInstallation,
--   AssetOSInstallation, TechnologyException), 4.7 step 5 "Classify
--   Current, Due Soon, Unsupported, Exception or Unknown", 4.8 ("Only
--   approved compatibility mappings can drive automated recommendations";
--   "Recommended targets must match type, make, model and hardware
--   revision"; "Unknown installed versions create an assessment gap";
--   "Unsupported firmware/OS can set Security Non-Compliant unless an
--   active exception applies"), 5 Technology domain ("current firmware,
--   OS/build, patch, lifecycle status, recommended target and history"),
--   5.1.16 "Installed or target version must have approved mapping or
--   explicit exception". Plan in docs/asset-contract-management.md.
--
-- WHAT THIS DOES
-- --------------
--   1. asset_firmware_installation / asset_os_installation -- the BRD 4.6
--      history: release, installed date, source, previous version, result
--      and rollback (firmware), build / patch level and licence (OS),
--      evidence, current flag (one current row per asset). The asset s
--      current version stays in its form fields (firmware_version,
--      operating_system, os_build_patch_level) so the form, the save
--      validation and the history agree; existing values get a starting
--      history row (source "Existing value (430)").
--   2. asset_technology_exception -- BRD 4.6 TechnologyException: asset or
--      model, firmware or OS version, reason, compensating controls,
--      owner, approver, expiry and review date; requested, then approved /
--      rejected by a different person, withdrawn by the requester or
--      revoked; an approved exception is active until its expiry date.
--      (Exception Centre s exception_request is bound to a compliance gap
--      -- custom_gap_id NOT NULL and the gap analysis workflow -- so it is
--      not reused; decision D20.)
--   3. One rule set, used by the save, the installation record and the
--      status view: fn_asset_tech_compatible (approved, active, in-effect
--      compatibility for the assets type / model / make, hardware revision
--      respected), fn_asset_tech_exception_active, fn_asset_fw_release_label
--      / fn_asset_os_release_label, and fn_asset_technology_status -- per
--      asset and technology: current version, release status, support
--      dates, recommended target (firmware: a RECOMMENDED release with an
--      approved compatibility row for the assets model and hardware
--      revision; OS: an approved-baseline release with an approved row for
--      the model) and the 4.7 classification (decision D19).
--   4. sp_asset_register_save re-issued with two changes only: an
--      installed firmware / OS without an approved mapping is now an ERROR
--      unless an active technology exception covers it (5.1.16; it was a
--      warning in 428 until exceptions existed -- D14), and a change of
--      firmware / OS / patch level on the form writes a history row
--      (source "Asset form"). The rollback restores the 428 body verbatim.
--   5. sp_asset_tech_install_record (Technology tab: full BRD detail),
--      sp_asset_tech_install_apply (internal, shared by the form save and
--      the record), sp_asset_tech_exception_request / _decide,
--      sp_asset_technology_get (status, history, exceptions).
--
-- NOT DONE HERE: assessment gap + validation task for UNKNOWN (tasks,
--   Phase 6); campaigns / bulk execution (4.7 steps 6-8, Phase 6); setting
--   Non-Compliant automatically (the BRD says "can"; the lifecycle offers
--   Active -> Non-Compliant, 429); exceptions in the Exception Centre list.
--
-- ERROR NUMBERS: 54320-54349
--   54320 organization not found          54321 asset not found
--   54322 asset changed by someone else   54323 technology must be FIRMWARE or OS
--   54324 release not available           54325 installed date missing / future
--   54326 source required                 54327 result must be Successful / Failed
--   54328 no approved mapping, no exception 54330 exception scope ASSET / MODEL
--   54331 reason + controls required      54332 owner not valid
--   54333 expiry / review dates           54334 already covered / pending
--   54335 exception not found             54336 wrong state for the decision
--   54337 segregation of duties           54338 note required
--   54339 only the requester can withdraw 54340 exception changed by someone else
--   54341 unknown decision                54342 the asset has no model
--
-- ALSO EDITED: API (AssetConfig service / controller / models), Web proxy,
--   asset-register.cshtml + asset-register.js, docs.
-- DEPENDS ON: 426, 427, 428, 429.
-- Rollback: 430_asset_installed_technology_rollback.sql
-- Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOEXEC OFF;
GO

-- The re-issued save reads these columns / objects (guard on what the body uses).
IF OBJECT_ID('grac_practice.sp_asset_lifecycle_transition','P') IS NULL
   OR OBJECT_ID('grac_practice.asset_firmware_compatibility','U') IS NULL
   OR OBJECT_ID('grac_practice.asset_os_compatibility','U') IS NULL
   OR OBJECT_ID('grac_practice.fn_asset_form_evaluate') IS NULL
   OR COL_LENGTH('grac_practice.organization_dependency_asset','template_id') IS NULL
   OR COL_LENGTH('grac_practice.asset_firmware_compatibility','hardware_revision') IS NULL
   OR COL_LENGTH('grac_practice.asset_os_release','is_approved_baseline') IS NULL
   OR NOT EXISTS (SELECT 1 FROM grac_practice.asset_field_definition WHERE field_key = N'firmware_version')
   OR NOT EXISTS (SELECT 1 FROM grac_practice.asset_field_definition WHERE field_key = N'operating_system')
BEGIN
    RAISERROR('ABORT (430): run 426 to 429 first.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. Tables
-- =====================================================================
IF OBJECT_ID('grac_practice.asset_firmware_installation','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_firmware_installation (
        installation_id      BIGINT         IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_asset_fw_install PRIMARY KEY,
        organization_id      BIGINT         NOT NULL,
        asset_id             BIGINT         NOT NULL
            CONSTRAINT fk_pm_asset_fw_install_asset REFERENCES grac_practice.organization_dependency_asset(asset_id),
        release_id           BIGINT         NOT NULL
            CONSTRAINT fk_pm_asset_fw_install_release REFERENCES grac_practice.asset_firmware_release(release_id),
        installed_date       DATE           NULL,      -- NULL only on the 430 starting rows
        source               NVARCHAR(100)  NOT NULL,
        previous_release_id  BIGINT         NULL
            CONSTRAINT fk_pm_asset_fw_install_prev REFERENCES grac_practice.asset_firmware_release(release_id),
        result               NVARCHAR(20)   NOT NULL
            CONSTRAINT ck_pm_asset_fw_install_result CHECK (result IN (N'SUCCESSFUL', N'FAILED')),
        rollback_note        NVARCHAR(1000) NULL,
        evidence_text        NVARCHAR(1000) NULL,
        is_current           BIT            NOT NULL CONSTRAINT df_pm_asset_fw_install_current DEFAULT 0,
        entered_by           NVARCHAR(100)  NOT NULL CONSTRAINT df_pm_asset_fw_install_eby DEFAULT N'system',
        entered_dt           DATETIME2      NOT NULL CONSTRAINT df_pm_asset_fw_install_edt DEFAULT SYSUTCDATETIME()
    );
    CREATE INDEX ix_pm_asset_fw_install_asset ON grac_practice.asset_firmware_installation(asset_id, entered_dt DESC);
    CREATE UNIQUE INDEX ux_pm_asset_fw_install_current ON grac_practice.asset_firmware_installation(asset_id) WHERE is_current = 1;
    PRINT '430: asset_firmware_installation created.';
END
GO

IF OBJECT_ID('grac_practice.asset_os_installation','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_os_installation (
        installation_id            BIGINT         IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_asset_os_install PRIMARY KEY,
        organization_id            BIGINT         NOT NULL,
        asset_id                   BIGINT         NOT NULL
            CONSTRAINT fk_pm_asset_os_install_asset REFERENCES grac_practice.organization_dependency_asset(asset_id),
        release_id                 BIGINT         NOT NULL
            CONSTRAINT fk_pm_asset_os_install_release REFERENCES grac_practice.asset_os_release(release_id),
        build_patch_level          NVARCHAR(100)  NULL,
        installed_date             DATE           NULL,  -- NULL only on the 430 starting rows
        source                     NVARCHAR(100)  NOT NULL,
        licence_reference          NVARCHAR(400)  NULL,
        previous_release_id        BIGINT         NULL
            CONSTRAINT fk_pm_asset_os_install_prev REFERENCES grac_practice.asset_os_release(release_id),
        previous_build_patch_level NVARCHAR(100)  NULL,
        evidence_text              NVARCHAR(1000) NULL,
        is_current                 BIT            NOT NULL CONSTRAINT df_pm_asset_os_install_current DEFAULT 0,
        entered_by                 NVARCHAR(100)  NOT NULL CONSTRAINT df_pm_asset_os_install_eby DEFAULT N'system',
        entered_dt                 DATETIME2      NOT NULL CONSTRAINT df_pm_asset_os_install_edt DEFAULT SYSUTCDATETIME()
    );
    CREATE INDEX ix_pm_asset_os_install_asset ON grac_practice.asset_os_installation(asset_id, entered_dt DESC);
    CREATE UNIQUE INDEX ux_pm_asset_os_install_current ON grac_practice.asset_os_installation(asset_id) WHERE is_current = 1;
    PRINT '430: asset_os_installation created.';
END
GO

IF OBJECT_ID('grac_practice.asset_technology_exception','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_technology_exception (
        exception_id             BIGINT         IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_asset_tech_exc PRIMARY KEY,
        organization_id          BIGINT         NOT NULL,
        technology_kind          NVARCHAR(10)   NOT NULL
            CONSTRAINT ck_pm_asset_tech_exc_kind CHECK (technology_kind IN (N'FIRMWARE', N'OS')),
        asset_id                 BIGINT         NULL       -- set: this asset only; NULL: every asset of the model
            CONSTRAINT fk_pm_asset_tech_exc_asset REFERENCES grac_practice.organization_dependency_asset(asset_id),
        model_id                 BIGINT         NULL
            CONSTRAINT fk_pm_asset_tech_exc_model REFERENCES grac_practice.asset_model(model_id),
        firmware_release_id      BIGINT         NULL
            CONSTRAINT fk_pm_asset_tech_exc_fw REFERENCES grac_practice.asset_firmware_release(release_id),
        os_release_id            BIGINT         NULL
            CONSTRAINT fk_pm_asset_tech_exc_os REFERENCES grac_practice.asset_os_release(release_id),
        reason                   NVARCHAR(1000) NOT NULL,
        compensating_controls    NVARCHAR(1000) NOT NULL,
        owner_employee_id        BIGINT         NOT NULL
            CONSTRAINT fk_pm_asset_tech_exc_owner REFERENCES grac_practice.organization_employee(employee_id),
        expiry_date              DATE           NOT NULL,
        review_date              DATE           NULL,
        status                   NVARCHAR(20)   NOT NULL
            CONSTRAINT ck_pm_asset_tech_exc_status CHECK (status IN
                (N'PENDING_APPROVAL', N'APPROVED', N'REJECTED', N'WITHDRAWN', N'REVOKED')),
        requested_by             NVARCHAR(100)  NOT NULL,
        requested_by_employee_id BIGINT         NULL,
        requested_dt             DATETIME2      NOT NULL CONSTRAINT df_pm_asset_tech_exc_rdt DEFAULT SYSUTCDATETIME(),
        decided_by               NVARCHAR(100)  NULL,
        decided_by_employee_id   BIGINT         NULL,
        decided_dt               DATETIME2      NULL,
        decision_note            NVARCHAR(1000) NULL,
        record_version           ROWVERSION     NOT NULL,
        CONSTRAINT ck_pm_asset_tech_exc_scope CHECK (asset_id IS NOT NULL OR model_id IS NOT NULL),
        CONSTRAINT ck_pm_asset_tech_exc_release CHECK (
            (technology_kind = N'FIRMWARE' AND firmware_release_id IS NOT NULL AND os_release_id IS NULL) OR
            (technology_kind = N'OS' AND os_release_id IS NOT NULL AND firmware_release_id IS NULL)),
        CONSTRAINT ck_pm_asset_tech_exc_dates CHECK (review_date IS NULL OR review_date <= expiry_date)
    );
    CREATE INDEX ix_pm_asset_tech_exc_asset ON grac_practice.asset_technology_exception(asset_id, status);
    CREATE INDEX ix_pm_asset_tech_exc_model ON grac_practice.asset_technology_exception(organization_id, model_id, status);
    -- One request awaiting approval per scope and version (NULLs compare equal in a unique index).
    CREATE UNIQUE INDEX ux_pm_asset_tech_exc_pending ON grac_practice.asset_technology_exception
        (organization_id, technology_kind, asset_id, model_id, firmware_release_id, os_release_id)
        WHERE status = N'PENDING_APPROVAL';
    PRINT '430: asset_technology_exception created.';
END
GO

-- =====================================================================
-- 2. Rule functions (one place for the save, the record and the status)
-- =====================================================================
-- 1 = an approved, active (in-effect) compatibility row covers the release
-- for the asset type and model (model row, else make row, else type row);
-- a row restricted to a hardware revision applies to that revision only.
-- NULL when there is no release or no model to evaluate.
CREATE OR ALTER FUNCTION grac_practice.fn_asset_tech_compatible
    (@organization_id BIGINT, @kind NVARCHAR(10), @release_id BIGINT, @asset_type_id INT,
     @model_id BIGINT, @hardware_revision NVARCHAR(400))
RETURNS BIT
AS
BEGIN
    IF @release_id IS NULL OR @model_id IS NULL RETURN NULL;
    DECLARE @make INT = (SELECT make_id FROM grac_practice.asset_model WHERE model_id = @model_id);
    DECLARE @today DATE = CAST(SYSUTCDATETIME() AS DATE);
    IF @kind = N'FIRMWARE'
        RETURN CASE WHEN EXISTS (
            SELECT 1 FROM grac_practice.asset_firmware_compatibility c
             WHERE c.release_id = @release_id AND c.is_active = 1 AND c.approval_status = N'APPROVED'
               AND c.asset_type_id = @asset_type_id
               AND (c.organization_id IS NULL OR c.organization_id = @organization_id)
               AND (c.model_id = @model_id OR (c.model_id IS NULL AND (c.make_id = @make OR c.make_id IS NULL)))
               AND (c.hardware_revision IS NULL OR c.hardware_revision = @hardware_revision)
               AND (c.effective_from IS NULL OR c.effective_from <= @today)
               AND (c.effective_to IS NULL OR c.effective_to >= @today)) THEN 1 ELSE 0 END;
    RETURN CASE WHEN EXISTS (
        SELECT 1 FROM grac_practice.asset_os_compatibility c
         WHERE c.release_id = @release_id AND c.is_active = 1 AND c.approval_status = N'APPROVED'
           AND c.asset_type_id = @asset_type_id
           AND (c.organization_id IS NULL OR c.organization_id = @organization_id)
           AND (c.model_id = @model_id OR (c.model_id IS NULL AND (c.make_id = @make OR c.make_id IS NULL)))) THEN 1 ELSE 0 END;
END
GO

-- The approved, unexpired technology exception covering the asset (or,
-- for a model-wide exception, its model) and the version, if any.
CREATE OR ALTER FUNCTION grac_practice.fn_asset_tech_exception_active
    (@organization_id BIGINT, @asset_id BIGINT, @model_id BIGINT, @kind NVARCHAR(10), @release_id BIGINT)
RETURNS TABLE
AS
RETURN
    SELECT TOP 1 e.exception_id AS ExceptionId, e.expiry_date AS ExpiryDate
      FROM grac_practice.asset_technology_exception e
     WHERE e.organization_id = @organization_id AND e.technology_kind = @kind AND e.status = N'APPROVED'
       AND e.expiry_date >= CAST(SYSUTCDATETIME() AS DATE)
       AND ((@kind = N'FIRMWARE' AND e.firmware_release_id = @release_id) OR (@kind = N'OS' AND e.os_release_id = @release_id))
       AND ((@asset_id IS NOT NULL AND e.asset_id = @asset_id) OR (e.asset_id IS NULL AND e.model_id = @model_id))
     ORDER BY CASE WHEN e.asset_id IS NULL THEN 1 ELSE 0 END, e.expiry_date DESC;
GO

-- Display labels (same wording as the MASTER:FIRMWARE / MASTER:OS_RELEASE pickers, 428).
CREATE OR ALTER FUNCTION grac_practice.fn_asset_fw_release_label (@release_id BIGINT)
RETURNS NVARCHAR(400)
AS
BEGIN
    RETURN (SELECT CONCAT(p.product_name, N' ', r.version, CASE WHEN r.build IS NULL THEN N'' ELSE N' build ' + r.build END)
              FROM grac_practice.asset_firmware_release r
              JOIN grac_practice.asset_firmware_product p ON p.product_id = r.product_id
             WHERE r.release_id = @release_id);
END
GO

CREATE OR ALTER FUNCTION grac_practice.fn_asset_os_release_label (@release_id BIGINT)
RETURNS NVARCHAR(400)
AS
BEGIN
    RETURN (SELECT CONCAT(p.product_name, CASE WHEN r.edition IS NULL THEN N'' ELSE N' ' + r.edition END, N' ', r.version,
                          CASE WHEN r.architecture IS NULL THEN N'' ELSE N' ' + r.architecture END)
              FROM grac_practice.asset_os_release r
              JOIN grac_practice.asset_os_product p ON p.product_id = r.product_id
             WHERE r.release_id = @release_id);
END
GO

-- Per asset and technology: current version, status, recommended target
-- and the BRD 4.7 classification (D19):
--   NOT_APPLICABLE  no version and the assets form has no field for it
--   UNKNOWN         the form has the field but no version is recorded (4.8)
--   UNSUPPORTED     release EOS / EOL / Withdrawn (firmware), EOS / Unsupported
--                   (OS), or no approved compatibility row for the model
--   EXCEPTION       unsupported, but an active technology exception covers it
--   DUE_SOON        firmware Deprecated, OS Approaching EOS
--   CURRENT         otherwise
CREATE OR ALTER FUNCTION grac_practice.fn_asset_technology_status (@organization_id BIGINT, @asset_id BIGINT)
RETURNS TABLE
AS
RETURN
WITH base AS (
    SELECT a.asset_id, a.asset_type_id, a.template_id,
           (SELECT TOP 1 v.value_ref FROM grac_practice.asset_field_value v
              JOIN grac_practice.asset_field_definition d ON d.field_definition_id = v.field_definition_id AND d.field_key = N'model'
             WHERE v.asset_id = a.asset_id) AS model_id,
           (SELECT TOP 1 v.value_text FROM grac_practice.asset_field_value v
              JOIN grac_practice.asset_field_definition d ON d.field_definition_id = v.field_definition_id AND d.field_key = N'hardware_revision'
             WHERE v.asset_id = a.asset_id) AS hw_rev,
           (SELECT TOP 1 v.value_ref FROM grac_practice.asset_field_value v
              JOIN grac_practice.asset_field_definition d ON d.field_definition_id = v.field_definition_id AND d.field_key = N'firmware_version'
             WHERE v.asset_id = a.asset_id) AS fw_id,
           (SELECT TOP 1 v.value_ref FROM grac_practice.asset_field_value v
              JOIN grac_practice.asset_field_definition d ON d.field_definition_id = v.field_definition_id AND d.field_key = N'operating_system'
             WHERE v.asset_id = a.asset_id) AS os_id,
           (SELECT TOP 1 v.value_text FROM grac_practice.asset_field_value v
              JOIN grac_practice.asset_field_definition d ON d.field_definition_id = v.field_definition_id AND d.field_key = N'os_build_patch_level'
             WHERE v.asset_id = a.asset_id) AS os_patch,
           CASE WHEN EXISTS (SELECT 1 FROM grac_practice.asset_form_template_field f
                               JOIN grac_practice.asset_field_definition d ON d.field_definition_id = f.field_definition_id
                              WHERE f.template_id = a.template_id AND d.field_key = N'firmware_version') THEN 1 ELSE 0 END AS fw_on_form,
           CASE WHEN EXISTS (SELECT 1 FROM grac_practice.asset_form_template_field f
                               JOIN grac_practice.asset_field_definition d ON d.field_definition_id = f.field_definition_id
                              WHERE f.template_id = a.template_id AND d.field_key = N'operating_system') THEN 1 ELSE 0 END AS os_on_form
      FROM grac_practice.organization_dependency_asset a
     WHERE a.organization_id = @organization_id AND (@asset_id IS NULL OR a.asset_id = @asset_id)
), t AS (
    SELECT b.asset_id, N'FIRMWARE' AS kind, b.fw_on_form AS applicable, r.release_id AS current_release_id,
           CASE WHEN r.release_id IS NULL THEN NULL ELSE grac_practice.fn_asset_fw_release_label(r.release_id) END AS current_label,
           s.status_code, s.status_name, CAST(NULL AS NVARCHAR(400)) AS build_patch_level,
           CAST(NULL AS NVARCHAR(100)) AS latest_approved_build, CAST(NULL AS NVARCHAR(100)) AS minimum_compliant_build,
           COALESCE(r.standard_support_end_date, r.security_fix_end_date) AS support_end_date, r.end_of_life_date,
           CASE WHEN s.status_code IN (N'EOS', N'EOL', N'WITHDRAWN') THEN 1 ELSE 0 END AS unsupported_status,
           CASE WHEN s.status_code = N'DEPRECATED' THEN 1 ELSE 0 END AS due_soon_status,
           grac_practice.fn_asset_tech_compatible(@organization_id, N'FIRMWARE', r.release_id, b.asset_type_id, b.model_id, b.hw_rev) AS compatible,
           rec.release_id AS recommended_release_id, x.ExceptionId AS exception_id, x.ExpiryDate AS exception_expiry, b.model_id
      FROM base b
      LEFT JOIN grac_practice.asset_firmware_release r ON r.release_id = b.fw_id
      LEFT JOIN grac_practice.entity_status_master s ON s.entity_status_id = r.current_status_id
      OUTER APPLY (SELECT TOP 1 r2.release_id
                     FROM grac_practice.asset_firmware_compatibility c
                     JOIN grac_practice.asset_firmware_release r2 ON r2.release_id = c.release_id
                     JOIN grac_practice.entity_status_master s2 ON s2.entity_status_id = r2.current_status_id
                    WHERE c.model_id = b.model_id AND c.asset_type_id = b.asset_type_id
                      AND c.is_active = 1 AND c.approval_status = N'APPROVED'
                      AND (c.organization_id IS NULL OR c.organization_id = @organization_id)
                      AND (r2.organization_id IS NULL OR r2.organization_id = @organization_id)
                      AND (c.hardware_revision IS NULL OR c.hardware_revision = b.hw_rev)
                      AND (c.effective_from IS NULL OR c.effective_from <= CAST(SYSUTCDATETIME() AS DATE))
                      AND (c.effective_to IS NULL OR c.effective_to >= CAST(SYSUTCDATETIME() AS DATE))
                      AND s2.status_code = N'RECOMMENDED'
                    ORDER BY CASE WHEN c.hardware_revision IS NULL THEN 1 ELSE 0 END, r2.release_date DESC, r2.release_id DESC) rec
      OUTER APPLY grac_practice.fn_asset_tech_exception_active(@organization_id, b.asset_id, b.model_id, N'FIRMWARE', r.release_id) x
    UNION ALL
    SELECT b.asset_id, N'OS', b.os_on_form, r.release_id,
           CASE WHEN r.release_id IS NULL THEN NULL ELSE grac_practice.fn_asset_os_release_label(r.release_id) END,
           s.status_code, s.status_name, b.os_patch, r.latest_approved_build, r.minimum_compliant_build,
           COALESCE(r.extended_support_end_date, r.mainstream_support_end_date, r.security_update_end_date), r.end_of_life_date,
           CASE WHEN s.status_code IN (N'EOS', N'UNSUPPORTED') THEN 1 ELSE 0 END,
           CASE WHEN s.status_code = N'APPROACHING_EOS' THEN 1 ELSE 0 END,
           grac_practice.fn_asset_tech_compatible(@organization_id, N'OS', r.release_id, b.asset_type_id, b.model_id, NULL),
           rec.release_id, x.ExceptionId, x.ExpiryDate, b.model_id
      FROM base b
      LEFT JOIN grac_practice.asset_os_release r ON r.release_id = b.os_id
      LEFT JOIN grac_practice.entity_status_master s ON s.entity_status_id = r.current_status_id
      OUTER APPLY (SELECT TOP 1 r2.release_id
                     FROM grac_practice.asset_os_compatibility c
                     JOIN grac_practice.asset_os_release r2 ON r2.release_id = c.release_id
                     JOIN grac_practice.entity_status_master s2 ON s2.entity_status_id = r2.current_status_id
                    WHERE c.model_id = b.model_id AND c.asset_type_id = b.asset_type_id
                      AND c.is_active = 1 AND c.approval_status = N'APPROVED'
                      AND (c.organization_id IS NULL OR c.organization_id = @organization_id)
                      AND (r2.organization_id IS NULL OR r2.organization_id = @organization_id)
                      AND r2.is_approved_baseline = 1
                      AND s2.status_code IN (N'APPROVED', N'SUPPORTED', N'EXTENDED_SUPPORT')
                    ORDER BY r2.release_date DESC, r2.release_id DESC) rec
      OUTER APPLY grac_practice.fn_asset_tech_exception_active(@organization_id, b.asset_id, b.model_id, N'OS', r.release_id) x
)
SELECT t.asset_id AS AssetId, t.kind AS Kind, t.applicable AS Applicable,
       t.current_release_id AS CurrentReleaseId, t.current_label AS CurrentLabel,
       t.status_code AS ReleaseStatusCode, t.status_name AS ReleaseStatusName, t.build_patch_level AS BuildPatchLevel,
       t.latest_approved_build AS LatestApprovedBuild, t.minimum_compliant_build AS MinimumCompliantBuild,
       t.support_end_date AS SupportEndDate, t.end_of_life_date AS EndOfLifeDate, t.compatible AS Compatible,
       t.recommended_release_id AS RecommendedReleaseId,
       CASE WHEN t.recommended_release_id IS NULL THEN NULL
            WHEN t.kind = N'FIRMWARE' THEN grac_practice.fn_asset_fw_release_label(t.recommended_release_id)
            ELSE grac_practice.fn_asset_os_release_label(t.recommended_release_id) END AS RecommendedLabel,
       t.exception_id AS ExceptionId, t.exception_expiry AS ExceptionExpiry, t.model_id AS ModelId,
       CASE WHEN t.current_release_id IS NULL THEN CASE WHEN t.applicable = 1 THEN N'UNKNOWN' ELSE N'NOT_APPLICABLE' END
            WHEN t.unsupported_status = 1 OR t.compatible = 0 THEN CASE WHEN t.exception_id IS NOT NULL THEN N'EXCEPTION' ELSE N'UNSUPPORTED' END
            WHEN t.due_soon_status = 1 THEN N'DUE_SOON'
            ELSE N'CURRENT' END AS Classification,
       CASE WHEN t.current_release_id IS NULL THEN CASE WHEN t.applicable = 1 THEN N'No installed version is recorded; an assessment is needed.' END
            WHEN t.unsupported_status = 1 THEN CONCAT(N'Release status is ', t.status_name, N'.')
            WHEN t.compatible = 0 THEN N'No approved compatibility record covers this version for the model.'
            WHEN t.due_soon_status = 1 THEN CONCAT(N'Release status is ', t.status_name, N'.')
            WHEN t.compatible IS NULL THEN N'The asset has no model, so compatibility is not evaluated.' END AS ClassificationReason
  FROM t;
GO
PRINT '430: technology rule functions created.';
GO

-- =====================================================================
-- 3. Installation write (internal; the form save and the record share it)
-- =====================================================================
-- Writes one history row; a successful installation becomes the current
-- one (the previous current row is kept as history). @update_value = 1
-- also writes the assets form fields (the form save writes them itself).
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_tech_install_apply
    @organization_id     BIGINT,
    @asset_id            BIGINT,
    @kind                NVARCHAR(10),
    @release_id          BIGINT,
    @build_patch_level   NVARCHAR(100)  = NULL,
    @installed_date      DATE           = NULL,
    @source              NVARCHAR(100),
    @result              NVARCHAR(20)   = N'SUCCESSFUL',
    @rollback_note       NVARCHAR(1000) = NULL,
    @licence_reference   NVARCHAR(400)  = NULL,
    @evidence_text       NVARCHAR(1000) = NULL,
    @update_value        BIT            = 0,
    @actor               NVARCHAR(100)  = N'system',
    @out_installation_id BIGINT         = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @result = ISNULL(@result, N'SUCCESSFUL');
    DECLARE @prev BIGINT, @prev_build NVARCHAR(100);

    BEGIN TRAN;
    IF @kind = N'FIRMWARE'
    BEGIN
        SELECT @prev = release_id FROM grac_practice.asset_firmware_installation WHERE asset_id = @asset_id AND is_current = 1;
        IF @result = N'SUCCESSFUL'
            UPDATE grac_practice.asset_firmware_installation SET is_current = 0 WHERE asset_id = @asset_id AND is_current = 1;
        INSERT grac_practice.asset_firmware_installation
            (organization_id, asset_id, release_id, installed_date, source, previous_release_id, result,
             rollback_note, evidence_text, is_current, entered_by)
        VALUES (@organization_id, @asset_id, @release_id, @installed_date, @source, @prev, @result,
                @rollback_note, @evidence_text, CASE WHEN @result = N'SUCCESSFUL' THEN 1 ELSE 0 END, @actor);
        SET @out_installation_id = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        SELECT @prev = release_id, @prev_build = build_patch_level
          FROM grac_practice.asset_os_installation WHERE asset_id = @asset_id AND is_current = 1;
        UPDATE grac_practice.asset_os_installation SET is_current = 0 WHERE asset_id = @asset_id AND is_current = 1;
        INSERT grac_practice.asset_os_installation
            (organization_id, asset_id, release_id, build_patch_level, installed_date, source, licence_reference,
             previous_release_id, previous_build_patch_level, evidence_text, is_current, entered_by)
        VALUES (@organization_id, @asset_id, @release_id, @build_patch_level, @installed_date, @source, @licence_reference,
                @prev, @prev_build, @evidence_text, 1, @actor);
        SET @out_installation_id = SCOPE_IDENTITY();
    END

    IF @update_value = 1 AND @result = N'SUCCESSFUL'
    BEGIN
        DECLARE @vals TABLE (field_key NVARCHAR(100) PRIMARY KEY, val NVARCHAR(400) NULL, ref BIGINT NULL);
        INSERT @vals (field_key, val, ref)
        VALUES (CASE WHEN @kind = N'FIRMWARE' THEN N'firmware_version' ELSE N'operating_system' END,
                CAST(@release_id AS NVARCHAR(40)), @release_id);
        IF @kind = N'OS'
            INSERT @vals (field_key, val, ref) VALUES (N'os_build_patch_level', NULLIF(LTRIM(RTRIM(@build_patch_level)), N''), NULL);
        DELETE v
          FROM grac_practice.asset_field_value v
          JOIN grac_practice.asset_field_definition d ON d.field_definition_id = v.field_definition_id
          JOIN @vals x ON x.field_key = d.field_key AND x.val IS NULL
         WHERE v.asset_id = @asset_id;
        MERGE grac_practice.asset_field_value AS tgt
        USING (SELECT d.field_definition_id, x.val, x.ref
                 FROM @vals x JOIN grac_practice.asset_field_definition d ON d.field_key = x.field_key
                WHERE x.val IS NOT NULL) AS src
        ON tgt.asset_id = @asset_id AND tgt.field_definition_id = src.field_definition_id
        WHEN MATCHED AND tgt.value_text <> src.val THEN
            UPDATE SET value_text = src.val, value_number = TRY_CONVERT(DECIMAL(38, 6), src.val), value_date = NULL,
                       value_ref = src.ref, updated_by = @actor, updated_dt = SYSUTCDATETIME()
        WHEN NOT MATCHED BY TARGET THEN
            INSERT (asset_id, field_definition_id, value_text, value_number, value_date, value_ref, entered_by)
            VALUES (@asset_id, src.field_definition_id, src.val, TRY_CONVERT(DECIMAL(38, 6), src.val), NULL, src.ref, @actor);
        -- Touch the asset so an open form with the old version is refused on save (record_version).
        UPDATE grac_practice.organization_dependency_asset
           SET updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE asset_id = @asset_id;
    END
    COMMIT;
END
GO

-- Starting history row for versions already on assets.
INSERT grac_practice.asset_firmware_installation
    (organization_id, asset_id, release_id, installed_date, source, previous_release_id, result, is_current, entered_by)
SELECT a.organization_id, v.asset_id, r.release_id, NULL, N'Existing value (430)', NULL, N'SUCCESSFUL', 1, N'seed-430'
  FROM grac_practice.asset_field_value v
  JOIN grac_practice.asset_field_definition d ON d.field_definition_id = v.field_definition_id AND d.field_key = N'firmware_version'
  JOIN grac_practice.organization_dependency_asset a ON a.asset_id = v.asset_id
  JOIN grac_practice.asset_firmware_release r ON r.release_id = v.value_ref
 WHERE NOT EXISTS (SELECT 1 FROM grac_practice.asset_firmware_installation i WHERE i.asset_id = v.asset_id);
PRINT CONCAT('430: firmware starting rows: ', @@ROWCOUNT);
INSERT grac_practice.asset_os_installation
    (organization_id, asset_id, release_id, build_patch_level, installed_date, source, is_current, entered_by)
SELECT a.organization_id, v.asset_id, r.release_id,
       (SELECT TOP 1 LEFT(pv.value_text, 100) FROM grac_practice.asset_field_value pv
          JOIN grac_practice.asset_field_definition pd ON pd.field_definition_id = pv.field_definition_id AND pd.field_key = N'os_build_patch_level'
         WHERE pv.asset_id = v.asset_id),
       NULL, N'Existing value (430)', 1, N'seed-430'
  FROM grac_practice.asset_field_value v
  JOIN grac_practice.asset_field_definition d ON d.field_definition_id = v.field_definition_id AND d.field_key = N'operating_system'
  JOIN grac_practice.organization_dependency_asset a ON a.asset_id = v.asset_id
  JOIN grac_practice.asset_os_release r ON r.release_id = v.value_ref
 WHERE NOT EXISTS (SELECT 1 FROM grac_practice.asset_os_installation i WHERE i.asset_id = v.asset_id);
PRINT CONCAT('430: OS starting rows: ', @@ROWCOUNT);
GO

-- =====================================================================
-- 4. sp_asset_register_save (428) re-issued -- two changes, marked 430
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_register_save
    @organization_id         BIGINT,
    @asset_id                BIGINT         = NULL,
    @asset_type_id           INT            = NULL,
    @values_json             NVARCHAR(MAX)  = N'{}',
    @hidden_decisions_json   NVARCHAR(MAX)  = NULL,
    @expected_record_version BIGINT         = NULL,
    @actor_employee_id       BIGINT         = NULL,
    @actor                   NVARCHAR(100)  = N'system',
    @out_asset_id            BIGINT         = NULL OUTPUT,
    @out_result              NVARCHAR(20)   = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    IF ISJSON(ISNULL(@values_json, N'')) <> 1 SET @values_json = N'{}';
    IF ISJSON(ISNULL(@hidden_decisions_json, N'')) <> 1 SET @hidden_decisions_json = N'{}';
    DECLARE @today DATE = CAST(SYSUTCDATETIME() AS DATE);

    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 54950, 'Organization not found.', 1;

    -- ---------------------------------------------------------- the record
    DECLARE @found BIT = 0, @rv BIGINT, @old_type INT, @template_id BIGINT;
    IF @asset_id IS NOT NULL
    BEGIN
        SELECT @found = 1, @rv = CONVERT(BIGINT, record_version), @old_type = asset_type_id, @template_id = template_id
          FROM grac_practice.organization_dependency_asset
         WHERE asset_id = @asset_id AND organization_id = @organization_id;
        IF @found = 0 THROW 54951, 'Asset not found for this organization.', 1;
        IF @expected_record_version IS NOT NULL AND @expected_record_version <> @rv
            THROW 54952, 'This asset was changed by someone else. Reload it and try again.', 1;
        IF @old_type IS NOT NULL AND @asset_type_id IS NOT NULL AND @asset_type_id <> @old_type
            THROW 54953, 'The asset type of a registered asset cannot change.', 1;
        SET @asset_type_id = ISNULL(@old_type, @asset_type_id);
    END
    IF @asset_type_id IS NULL
       OR (ISNULL(@old_type, -1) <> @asset_type_id
           AND NOT EXISTS (SELECT 1 FROM grac_practice.fn_asset_taxonomy_selectable() WHERE NodeKind = N'TYPE' AND NodeId = @asset_type_id))
        THROW 54954, 'Select an asset type that is active and in effect.', 1;

    -- Template: the version the asset was registered with, else the Active one (5.2.1).
    IF @template_id IS NULL
        SELECT @template_id = template_id FROM grac_practice.asset_form_template
         WHERE organization_id = @organization_id AND asset_type_id = @asset_type_id AND is_active_version = 1;
    IF @template_id IS NULL
        THROW 54955, 'This asset type has no Active form template. Activate one on Asset Form Templates first.', 1;

    DECLARE @sub_id INT, @cat_id INT;
    SELECT @sub_id = t.subcategory_id, @cat_id = s.asset_category_id
      FROM grac_practice.dependency_asset_type_master t
      JOIN grac_practice.dependency_asset_subcategory_master s ON s.subcategory_id = t.subcategory_id
     WHERE t.asset_type_id = @asset_type_id;

    -- ---------------------------------------------------------- template fields
    DECLARE @tf TABLE (
        field_definition_id INT PRIMARY KEY, field_key NVARCHAR(100) NOT NULL UNIQUE, label NVARCHAR(200) NOT NULL,
        data_type NVARCHAR(30) NOT NULL, lookup_source NVARCHAR(100) NULL, storage_kind NVARCHAR(10) NOT NULL,
        column_name NVARCHAR(128) NULL, editable BIT NOT NULL, default_value NVARCHAR(400) NULL,
        hidden_behavior NVARCHAR(10) NOT NULL, is_multi BIT NOT NULL);
    INSERT @tf
    SELECT d.field_definition_id, d.field_key, d.display_label, d.data_type_code, d.lookup_source, d.storage_kind, d.column_name,
           CASE WHEN dt.is_user_entered = 1 AND f.is_read_only = 0 AND d.storage_kind <> N'SYSTEM' AND d.is_system_field = 0
                 AND ISNULL(d.column_name, N'') NOT IN (N'organization_id', N'asset_type_id', N'asset_subcategory_id', N'asset_category_id')
                THEN 1 ELSE 0 END,
           f.default_value, f.hidden_value_behavior,
           CASE WHEN d.data_type_code IN (N'MULTI_SELECT', N'MULTI_USER') THEN 1 ELSE 0 END
      FROM grac_practice.asset_form_template_field f
      JOIN grac_practice.asset_field_definition d ON d.field_definition_id = f.field_definition_id
      JOIN grac_practice.asset_field_data_type_master dt ON dt.data_type_code = d.data_type_code
     WHERE f.template_id = @template_id;

    -- ---------------------------------------------------------- stored, submitted, effective
    DECLARE @stored TABLE (field_key NVARCHAR(100) PRIMARY KEY, val NVARCHAR(MAX) NULL);
    IF @asset_id IS NOT NULL
        INSERT @stored (field_key, val) SELECT FieldKey, Value FROM grac_practice.fn_asset_stored_values(@asset_id);

    DECLARE @sub TABLE (field_key NVARCHAR(100) PRIMARY KEY, val NVARCHAR(MAX) NULL);
    INSERT @sub (field_key, val)
    SELECT j.[key],
           CASE WHEN j.[type] = 4 THEN CASE WHEN EXISTS (SELECT 1 FROM OPENJSON(j.[value])) THEN j.[value] END
                WHEN j.[type] = 0 THEN NULL
                ELSE NULLIF(LTRIM(RTRIM(j.[value])), N'') END
      FROM OPENJSON(@values_json) j
      -- OPENJSON's [key] is Latin1_General_BIN2; compare in the database collation (Msg 468).
      JOIN @tf t ON t.field_key = j.[key] COLLATE DATABASE_DEFAULT AND t.editable = 1;
    -- New asset: template defaults for fields not supplied.
    IF @asset_id IS NULL
        INSERT @sub (field_key, val)
        SELECT t.field_key, t.default_value FROM @tf t
         WHERE t.editable = 1 AND t.default_value IS NOT NULL AND NOT EXISTS (SELECT 1 FROM @sub s WHERE s.field_key = t.field_key);

    DECLARE @eff TABLE (field_key NVARCHAR(100) PRIMARY KEY, val NVARCHAR(MAX) NULL, submitted BIT NOT NULL);
    INSERT @eff (field_key, val, submitted)
    SELECT t.field_key,
           CASE WHEN s.field_key IS NOT NULL THEN s.val ELSE st.val END,
           CASE WHEN s.field_key IS NOT NULL AND ISNULL(s.val, N'') <> ISNULL(st.val, N'') THEN 1 ELSE 0 END
      FROM @tf t
      LEFT JOIN @sub s ON s.field_key = t.field_key
      LEFT JOIN @stored st ON st.field_key = t.field_key;
    -- Taxonomy and legal entity follow the asset type and the organization.
    UPDATE e SET val = CASE t.column_name WHEN N'asset_type_id' THEN CAST(@asset_type_id AS NVARCHAR(40))
                                          WHEN N'asset_subcategory_id' THEN CAST(@sub_id AS NVARCHAR(40))
                                          WHEN N'asset_category_id' THEN CAST(@cat_id AS NVARCHAR(40))
                                          ELSE CAST(@organization_id AS NVARCHAR(40)) END
      FROM @eff e JOIN @tf t ON t.field_key = e.field_key
     WHERE t.column_name IN (N'asset_type_id', N'asset_subcategory_id', N'asset_category_id', N'organization_id');

    -- ---------------------------------------------------------- rules (5.1.14)
    DECLARE @eval_json NVARCHAR(MAX) = N'{' + ISNULL((
        SELECT STRING_AGG(CAST(CONCAT(N'"', STRING_ESCAPE(e.field_key, 'json'), N'":',
                    CASE WHEN t.is_multi = 1 AND ISJSON(e.val) = 1 THEN e.val
                         ELSE N'"' + STRING_ESCAPE(e.val, 'json') + N'"' END) AS NVARCHAR(MAX)), N',')
          FROM @eff e JOIN @tf t ON t.field_key = e.field_key
         WHERE e.val IS NOT NULL), N'') + N'}';
    DECLARE @ev TABLE (field_key NVARCHAR(100) PRIMARY KEY, is_visible INT NOT NULL, is_mandatory INT NOT NULL);
    INSERT @ev (field_key, is_visible, is_mandatory)
    SELECT FieldKey, IsVisible, IsMandatory FROM grac_practice.fn_asset_form_evaluate(@template_id, @eval_json);

    DECLARE @issues TABLE (severity NVARCHAR(10) NOT NULL, field_key NVARCHAR(100) NULL, message NVARCHAR(500) NOT NULL);

    -- Hidden fields holding a value (5.1.14): RETAIN keeps it; CLEAR / MIGRATE need a decision.
    DECLARE @decisions TABLE (field_key NVARCHAR(100) PRIMARY KEY, decision NVARCHAR(10) NOT NULL);
    INSERT @decisions (field_key, decision)
    SELECT j.[key], UPPER(j.[value]) FROM OPENJSON(@hidden_decisions_json) j WHERE UPPER(j.[value]) IN (N'RETAIN', N'CLEAR');
    INSERT @issues (severity, field_key, message)
    SELECT N'DECISION', t.field_key,
           CONCAT(N'"', t.label, N'" is hidden by the form rules but holds a value. Choose whether to keep it or clear it.')
      FROM @tf t
      JOIN @ev v ON v.field_key = t.field_key AND v.is_visible = 0
      JOIN @stored st ON st.field_key = t.field_key AND st.val IS NOT NULL
     WHERE t.editable = 1 AND t.hidden_behavior IN (N'CLEAR', N'MIGRATE')
       AND NOT EXISTS (SELECT 1 FROM @decisions d WHERE d.field_key = t.field_key);
    -- Hidden fields: never take a newly typed value; keep or clear the stored one.
    UPDATE e
       SET val = CASE WHEN ISNULL(d.decision, CASE WHEN t.hidden_behavior = N'RETAIN' THEN N'RETAIN' END) = N'CLEAR' THEN NULL ELSE st.val END,
           submitted = CASE WHEN ISNULL(d.decision, N'') = N'CLEAR' AND st.val IS NOT NULL THEN 1 ELSE 0 END
      FROM @eff e
      JOIN @tf t ON t.field_key = e.field_key AND t.editable = 1
      JOIN @ev v ON v.field_key = e.field_key AND v.is_visible = 0
      LEFT JOIN @stored st ON st.field_key = e.field_key
      LEFT JOIN @decisions d ON d.field_key = e.field_key;

    -- ---------------------------------------------------------- mandatory
    INSERT @issues (severity, field_key, message)
    SELECT N'ERROR', t.field_key, CONCAT(N'"', t.label, N'" is required.')
      FROM @tf t
      JOIN @ev v ON v.field_key = t.field_key AND v.is_visible = 1 AND v.is_mandatory = 1
      JOIN @eff e ON e.field_key = t.field_key
     WHERE t.editable = 1 AND e.val IS NULL;

    -- ---------------------------------------------------------- data types (changed values)
    INSERT @issues (severity, field_key, message)
    SELECT N'ERROR', t.field_key,
           CONCAT(N'"', t.label, N'" ', CASE
               WHEN t.data_type IN (N'DECIMAL', N'CURRENCY') THEN N'must be a number.'
               WHEN t.data_type = N'PERCENT' THEN N'must be a number from 0 to 100.'
               WHEN t.data_type = N'QUANTITY_UNIT' THEN N'must start with a number (for example "12 months").'
               WHEN t.data_type = N'DATE' THEN N'must be a date (yyyy-mm-dd).'
               WHEN t.data_type = N'YES_NO' THEN N'must be Yes or No.'
               ELSE N'is not valid.' END)
      FROM @tf t JOIN @eff e ON e.field_key = t.field_key
     WHERE t.editable = 1 AND e.submitted = 1 AND e.val IS NOT NULL
       AND (   (t.data_type IN (N'DECIMAL', N'CURRENCY') AND TRY_CONVERT(DECIMAL(38, 6), e.val) IS NULL)
            OR (t.data_type = N'PERCENT' AND ISNULL(TRY_CONVERT(DECIMAL(38, 6), e.val), -1) NOT BETWEEN 0 AND 100)
            OR (t.data_type = N'QUANTITY_UNIT' AND TRY_CONVERT(DECIMAL(38, 6), LEFT(e.val, CHARINDEX(N' ', e.val + N' ') - 1)) IS NULL)
            OR (t.data_type = N'DATE' AND TRY_CONVERT(DATE, e.val, 23) IS NULL)
            OR (t.data_type = N'YES_NO' AND e.val NOT IN (N'Yes', N'No')));

    -- ---------------------------------------------------------- lookup values (changed values)
    DECLARE @elems TABLE (field_key NVARCHAR(100) NOT NULL, elem NVARCHAR(400) NOT NULL);
    INSERT @elems (field_key, elem)
    SELECT e.field_key, LEFT(LTRIM(RTRIM(a.[value])), 400)
      FROM @eff e JOIN @tf t ON t.field_key = e.field_key
     CROSS APPLY OPENJSON(CASE WHEN t.is_multi = 1 AND ISJSON(e.val) = 1 THEN e.val
                               ELSE N'["' + STRING_ESCAPE(e.val, 'json') + N'"]' END) a
     WHERE t.editable = 1 AND e.submitted = 1 AND e.val IS NOT NULL AND t.lookup_source IS NOT NULL
       AND a.[value] IS NOT NULL AND LTRIM(RTRIM(a.[value])) <> N'';

    INSERT @issues (severity, field_key, message)
    SELECT DISTINCT N'ERROR', t.field_key,
           CASE WHEN t.lookup_source = N'MASTER:CONTRACT'
                THEN CONCAT(N'"', t.label, N'" is linked once contracts are available (Phase 5); leave it empty for now.')
                ELSE CONCAT(N'"', t.label, N'" has a value that is not in its list: ', x.elem, N'.') END
      FROM @elems x JOIN @tf t ON t.field_key = x.field_key
     WHERE t.lookup_source NOT IN (N'MASTER:COUNTRY', N'MASTER:CURRENCY')
       AND t.lookup_source NOT LIKE N'STATE:%'
       AND NOT (t.lookup_source LIKE N'OPTION:%' AND EXISTS (
                SELECT 1 FROM grac_practice.fn_asset_field_options(@organization_id) o
                 WHERE o.OptionGroup = N'asset_field.' + SUBSTRING(t.lookup_source, 8, 100) AND o.OptionValue = x.elem))
       AND NOT (t.lookup_source LIKE N'MASTER:%' AND t.lookup_source <> N'MASTER:CONTRACT' AND EXISTS (
                SELECT 1 FROM grac_practice.fn_asset_master_lookup(@organization_id) m
                 WHERE m.Source = t.lookup_source AND m.Value = x.elem))
       -- CIA ratings: the levels of the Active valuation configuration (same mapping as 422 / 423 template get).
       AND NOT (t.lookup_source = N'CONFIG:CIA_SCALE' AND EXISTS (
                SELECT 1 FROM grac_practice.asset_valuation_config c
                  JOIN grac_practice.asset_cia_scale_level l ON l.config_id = c.config_id
                 WHERE c.organization_id = @organization_id AND c.is_active_version = 1
                   AND CAST(l.score AS NVARCHAR(160)) = x.elem
                   AND l.dimension_code = CASE t.field_key WHEN N'confidentiality_rating' THEN N'C'
                                                           WHEN N'integrity_rating' THEN N'I'
                                                           WHEN N'availability_rating' THEN N'A' END));

    -- ---------------------------------------------------------- cross-field rules (5.1 / 5.1.16)
    DECLARE @num TABLE (field_key NVARCHAR(100) PRIMARY KEY, n DECIMAL(38, 6) NULL, d DATE NULL);
    INSERT @num (field_key, n, d)
    SELECT e.field_key,
           TRY_CONVERT(DECIMAL(38, 6), CASE WHEN t.data_type = N'QUANTITY_UNIT' THEN LEFT(e.val, CHARINDEX(N' ', e.val + N' ') - 1) ELSE e.val END),
           CASE WHEN t.data_type = N'DATE' THEN TRY_CONVERT(DATE, e.val, 23) END
      FROM @eff e JOIN @tf t ON t.field_key = e.field_key WHERE e.val IS NOT NULL;

    INSERT @issues (severity, field_key, message)
    SELECT r.severity, r.field_key, r.message
      FROM grac_practice.asset_field_validation_rule r
      JOIN @eff e ON e.field_key = r.field_key
      JOIN @num a ON a.field_key = r.field_key
      LEFT JOIN @eff eo ON eo.field_key = r.other_field_key
      LEFT JOIN @num b ON b.field_key = r.other_field_key
      LEFT JOIN @stored st ON st.field_key = r.field_key
     WHERE r.is_active = 1
       AND (e.submitted = 1 OR ISNULL(eo.submitted, 0) = 1)
       AND (   (r.rule_code = N'NOT_FUTURE'       AND a.d > @today)
            OR (r.rule_code = N'ON_OR_AFTER'      AND a.d < b.d)
            OR (r.rule_code = N'AFTER'            AND a.d <= b.d)
            OR (r.rule_code = N'NON_NEGATIVE'     AND a.n < 0)
            OR (r.rule_code = N'POSITIVE'         AND a.n <= 0)
            OR (r.rule_code = N'NOT_GREATER_THAN' AND a.n > b.n)
            OR (r.rule_code = N'NOT_BELOW_STORED' AND a.n < TRY_CONVERT(DECIMAL(38, 6), st.val)));

    -- Model must belong to the selected make and asset type (5.1.16).
    DECLARE @model_val NVARCHAR(MAX) = (SELECT val FROM @eff WHERE field_key = N'model'),
            @make_val  NVARCHAR(MAX) = (SELECT val FROM @eff WHERE field_key = N'manufacturer_make');
    DECLARE @model_id BIGINT = TRY_CONVERT(BIGINT, @model_val), @m_make INT, @m_type INT;
    IF @model_id IS NOT NULL
    BEGIN
        SELECT @m_make = make_id, @m_type = asset_type_id FROM grac_practice.asset_model WHERE model_id = @model_id;
        IF @m_type IS NOT NULL AND @m_type <> @asset_type_id
            INSERT @issues (severity, field_key, message) VALUES (N'ERROR', N'model', N'The selected model belongs to a different asset type.');
        IF @m_make IS NOT NULL AND (@make_val IS NULL OR TRY_CONVERT(INT, @make_val) <> @m_make)
            INSERT @issues (severity, field_key, message) VALUES (N'ERROR', N'model', N'The selected model does not belong to the selected make.');
    END

    -- Serial uniqueness within make / model: warning (no blocking policy configured).
    DECLARE @serial NVARCHAR(MAX) = (SELECT val FROM @eff WHERE field_key = N'serial_number' AND submitted = 1);
    IF @serial IS NOT NULL AND EXISTS (
        SELECT 1 FROM grac_practice.asset_field_value sv
          JOIN grac_practice.asset_field_definition sd ON sd.field_definition_id = sv.field_definition_id AND sd.field_key = N'serial_number'
          JOIN grac_practice.organization_dependency_asset a2 ON a2.asset_id = sv.asset_id AND a2.organization_id = @organization_id
          LEFT JOIN grac_practice.asset_field_value mv ON mv.asset_id = sv.asset_id
               AND mv.field_definition_id = (SELECT field_definition_id FROM grac_practice.asset_field_definition WHERE field_key = N'model')
          LEFT JOIN grac_practice.asset_field_value kv ON kv.asset_id = sv.asset_id
               AND kv.field_definition_id = (SELECT field_definition_id FROM grac_practice.asset_field_definition WHERE field_key = N'manufacturer_make')
         WHERE sv.value_text = @serial AND sv.asset_id <> ISNULL(@asset_id, -1)
           AND ISNULL(mv.value_text, N'') = ISNULL(@model_val, N'') AND ISNULL(kv.value_text, N'') = ISNULL(@make_val, N''))
        INSERT @issues (severity, field_key, message)
        VALUES (N'WARNING', N'serial_number', N'Another asset of this make and model already has this serial number.');

    -- 430: installed firmware / OS (5.1.16 "approved mapping or explicit exception", 4.8)
    -- An ERROR unless an active technology exception covers the asset (or its
    -- model) and the version; it was a warning in 428 until exceptions existed (D14, D19).
    DECLARE @fw BIGINT = TRY_CONVERT(BIGINT, (SELECT val FROM @eff WHERE field_key = N'firmware_version' AND submitted = 1)),
            @os BIGINT = TRY_CONVERT(BIGINT, (SELECT val FROM @eff WHERE field_key = N'operating_system' AND submitted = 1));
    DECLARE @hw_rev NVARCHAR(400) = LEFT((SELECT val FROM @eff WHERE field_key = N'hardware_revision'), 400);
    IF @fw IS NOT NULL AND @model_id IS NOT NULL
       AND grac_practice.fn_asset_tech_compatible(@organization_id, N'FIRMWARE', @fw, @asset_type_id, @model_id, @hw_rev) = 0
       AND NOT EXISTS (SELECT 1 FROM grac_practice.fn_asset_tech_exception_active(@organization_id, @asset_id, @model_id, N'FIRMWARE', @fw))
        INSERT @issues (severity, field_key, message)
        VALUES (N'ERROR', N'firmware_version', N'This firmware has no approved compatibility record for the model. Choose a compatible release, or save without it and request a technology exception on the Technology tab.');
    IF @os IS NOT NULL AND @model_id IS NOT NULL
       AND grac_practice.fn_asset_tech_compatible(@organization_id, N'OS', @os, @asset_type_id, @model_id, NULL) = 0
       AND NOT EXISTS (SELECT 1 FROM grac_practice.fn_asset_tech_exception_active(@organization_id, @asset_id, @model_id, N'OS', @os))
        INSERT @issues (severity, field_key, message)
        VALUES (N'ERROR', N'operating_system', N'This operating system has no approved compatibility record for the model. Choose a compatible release, or save without it and request a technology exception on the Technology tab.');

    -- Asset name is unique in the organization (existing constraint uq_pm_org_asset_name).
    DECLARE @name NVARCHAR(220) = LEFT((SELECT val FROM @eff WHERE field_key = N'asset_name'), 220);
    IF @name IS NOT NULL AND EXISTS (SELECT 1 FROM grac_practice.organization_dependency_asset
                                      WHERE organization_id = @organization_id AND asset_name = @name AND asset_id <> ISNULL(@asset_id, -1))
        INSERT @issues (severity, field_key, message) VALUES (N'ERROR', N'asset_name', N'Another asset in this organization already has this name.');

    -- ---------------------------------------------------------- stop or write
    IF EXISTS (SELECT 1 FROM @issues WHERE severity IN (N'ERROR', N'DECISION'))
    BEGIN
        SET @out_result = CASE WHEN EXISTS (SELECT 1 FROM @issues WHERE severity = N'ERROR') THEN N'INVALID' ELSE N'NEEDS_DECISION' END;
        SET @out_asset_id = @asset_id;
        SELECT severity AS Severity, field_key AS FieldKey, message AS Message FROM @issues
         ORDER BY CASE severity WHEN N'ERROR' THEN 0 WHEN N'DECISION' THEN 1 ELSE 2 END, field_key;
        RETURN;
    END

    DECLARE @col TABLE (column_name NVARCHAR(128) PRIMARY KEY, val NVARCHAR(MAX) NULL);
    INSERT @col (column_name, val)
    SELECT t.column_name, e.val FROM @tf t JOIN @eff e ON e.field_key = t.field_key
     WHERE t.storage_kind = N'COLUMN' AND t.editable = 1;
    DECLARE @in_tpl TABLE (column_name NVARCHAR(128) PRIMARY KEY);
    INSERT @in_tpl (column_name) SELECT column_name FROM @col;

    DECLARE @active_rs INT = (SELECT TOP 1 record_status_id FROM grac_practice.record_status_master
                               WHERE status_code = N'Active' OR status_name = N'Active' ORDER BY record_status_id);
    DECLARE @draft_id INT = grac_practice.fn_get_entity_status_id(N'Asset', N'DRAFT');
    DECLARE @before NVARCHAR(MAX) = (SELECT field_key AS fieldKey, val AS value FROM @stored FOR JSON PATH);
    DECLARE @to_status_id INT, @log_id BIGINT;

    BEGIN TRAN;
    IF @asset_id IS NULL
    BEGIN
        INSERT grac_practice.organization_dependency_asset
            (organization_id, asset_name, asset_category_id, asset_subcategory_id, asset_type_id, owner_id, location_id,
             purchase_dt, warranty_expiry_dt, amc_expiry_dt, criticality_id, remarks, status, record_status_id,
             lifecycle_status, template_id, current_status_id, entered_by)
        SELECT @organization_id, @name, @cat_id, @sub_id, @asset_type_id,
               TRY_CONVERT(BIGINT, (SELECT val FROM @col WHERE column_name = N'owner_id')),
               TRY_CONVERT(BIGINT, (SELECT val FROM @col WHERE column_name = N'location_id')),
               TRY_CONVERT(DATE, (SELECT val FROM @col WHERE column_name = N'purchase_dt'), 23),
               TRY_CONVERT(DATE, (SELECT val FROM @col WHERE column_name = N'warranty_expiry_dt'), 23),
               TRY_CONVERT(DATE, (SELECT val FROM @col WHERE column_name = N'amc_expiry_dt'), 23),
               TRY_CONVERT(INT, (SELECT val FROM @col WHERE column_name = N'criticality_id')),
               (SELECT val FROM @col WHERE column_name = N'remarks'),
               N'Active', ISNULL(@active_rs, 1), p.legacy_lifecycle_status, @template_id, @draft_id, @actor
          FROM grac_practice.asset_lifecycle_status_phase p WHERE p.status_code = N'DRAFT';
        SET @out_asset_id = SCOPE_IDENTITY();
        EXEC grac_practice.sp_pm_state_transition
             @entity_type = N'Asset', @entity_id = @out_asset_id,
             @from_status_code = NULL, @to_status_code = N'DRAFT',
             @actor_employee_id = @actor_employee_id, @actor_role_code = NULL,
             @reason_code = N'REGISTERED', @reason_text = NULL,
             @to_status_id = @to_status_id OUTPUT, @transition_log_id = @log_id OUTPUT;
    END
    ELSE
    BEGIN
        -- Only columns whose field is on the template change.
        UPDATE a
           SET asset_name = CASE WHEN EXISTS (SELECT 1 FROM @in_tpl WHERE column_name = N'asset_name') THEN @name ELSE a.asset_name END,
               asset_category_id = @cat_id, asset_subcategory_id = @sub_id, asset_type_id = @asset_type_id,
               owner_id = CASE WHEN EXISTS (SELECT 1 FROM @in_tpl WHERE column_name = N'owner_id')
                               THEN TRY_CONVERT(BIGINT, (SELECT val FROM @col WHERE column_name = N'owner_id')) ELSE a.owner_id END,
               location_id = CASE WHEN EXISTS (SELECT 1 FROM @in_tpl WHERE column_name = N'location_id')
                                  THEN TRY_CONVERT(BIGINT, (SELECT val FROM @col WHERE column_name = N'location_id')) ELSE a.location_id END,
               purchase_dt = CASE WHEN EXISTS (SELECT 1 FROM @in_tpl WHERE column_name = N'purchase_dt')
                                  THEN TRY_CONVERT(DATE, (SELECT val FROM @col WHERE column_name = N'purchase_dt'), 23) ELSE a.purchase_dt END,
               warranty_expiry_dt = CASE WHEN EXISTS (SELECT 1 FROM @in_tpl WHERE column_name = N'warranty_expiry_dt')
                                         THEN TRY_CONVERT(DATE, (SELECT val FROM @col WHERE column_name = N'warranty_expiry_dt'), 23) ELSE a.warranty_expiry_dt END,
               amc_expiry_dt = CASE WHEN EXISTS (SELECT 1 FROM @in_tpl WHERE column_name = N'amc_expiry_dt')
                                    THEN TRY_CONVERT(DATE, (SELECT val FROM @col WHERE column_name = N'amc_expiry_dt'), 23) ELSE a.amc_expiry_dt END,
               criticality_id = CASE WHEN EXISTS (SELECT 1 FROM @in_tpl WHERE column_name = N'criticality_id')
                                     THEN TRY_CONVERT(INT, (SELECT val FROM @col WHERE column_name = N'criticality_id')) ELSE a.criticality_id END,
               remarks = CASE WHEN EXISTS (SELECT 1 FROM @in_tpl WHERE column_name = N'remarks')
                              THEN (SELECT val FROM @col WHERE column_name = N'remarks') ELSE a.remarks END,
               template_id = @template_id,
               updated_by = @actor, updated_dt = SYSUTCDATETIME()
          FROM grac_practice.organization_dependency_asset a
         WHERE a.asset_id = @asset_id;
        SET @out_asset_id = @asset_id;
    END

    -- VALUE fields on the template: clear the empty ones, upsert the rest.
    DELETE v
      FROM grac_practice.asset_field_value v
      JOIN @tf t ON t.field_definition_id = v.field_definition_id AND t.storage_kind = N'VALUE' AND t.editable = 1
      JOIN @eff e ON e.field_key = t.field_key
     WHERE v.asset_id = @out_asset_id AND e.val IS NULL;
    MERGE grac_practice.asset_field_value AS tgt
    USING (
        SELECT t.field_definition_id, e.val,
               TRY_CONVERT(DECIMAL(38, 6), CASE WHEN t.data_type = N'QUANTITY_UNIT' THEN LEFT(e.val, CHARINDEX(N' ', e.val + N' ') - 1) ELSE e.val END) AS n,
               CASE WHEN t.data_type = N'DATE' THEN TRY_CONVERT(DATE, e.val, 23) END AS d,
               CASE WHEN t.lookup_source LIKE N'MASTER:%' AND t.is_multi = 0 THEN TRY_CONVERT(BIGINT, e.val) END AS r
          FROM @tf t JOIN @eff e ON e.field_key = t.field_key
         WHERE t.storage_kind = N'VALUE' AND t.editable = 1 AND e.val IS NOT NULL
    ) AS src
    ON tgt.asset_id = @out_asset_id AND tgt.field_definition_id = src.field_definition_id
    WHEN MATCHED AND tgt.value_text <> src.val THEN
        UPDATE SET value_text = src.val, value_number = src.n, value_date = src.d, value_ref = src.r,
                   updated_by = @actor, updated_dt = SYSUTCDATETIME()
    WHEN NOT MATCHED BY TARGET THEN
        INSERT (asset_id, field_definition_id, value_text, value_number, value_date, value_ref, entered_by)
        VALUES (@out_asset_id, src.field_definition_id, src.val, src.n, src.d, src.r, @actor);

    -- 430: installed firmware / OS history (BRD 4.6) when the form changes them.
    DECLARE @fw_old BIGINT = TRY_CONVERT(BIGINT, (SELECT val FROM @stored WHERE field_key = N'firmware_version')),
            @fw_new BIGINT = TRY_CONVERT(BIGINT, (SELECT val FROM @eff WHERE field_key = N'firmware_version')),
            @os_old BIGINT = TRY_CONVERT(BIGINT, (SELECT val FROM @stored WHERE field_key = N'operating_system')),
            @os_new BIGINT = TRY_CONVERT(BIGINT, (SELECT val FROM @eff WHERE field_key = N'operating_system'));
    DECLARE @patch_old NVARCHAR(100) = LEFT((SELECT val FROM @stored WHERE field_key = N'os_build_patch_level'), 100),
            @patch_new NVARCHAR(100) = LEFT((SELECT val FROM @eff WHERE field_key = N'os_build_patch_level'), 100);
    DECLARE @fw_on_tpl BIT = CASE WHEN EXISTS (SELECT 1 FROM @tf WHERE field_key = N'firmware_version' AND editable = 1) THEN 1 ELSE 0 END,
            @os_on_tpl BIT = CASE WHEN EXISTS (SELECT 1 FROM @tf WHERE field_key = N'operating_system' AND editable = 1) THEN 1 ELSE 0 END;
    DECLARE @inst_id BIGINT, @form_source NVARCHAR(100) = N'Asset form';
    IF @fw_on_tpl = 1 AND @fw_new IS NOT NULL AND ISNULL(@fw_old, -1) <> @fw_new
    BEGIN
        EXEC grac_practice.sp_asset_tech_install_apply
             @organization_id = @organization_id, @asset_id = @out_asset_id, @kind = N'FIRMWARE', @release_id = @fw_new,
             @installed_date = @today, @source = @form_source, @update_value = 0, @actor = @actor,
             @out_installation_id = @inst_id OUTPUT;
    END
    ELSE IF @fw_on_tpl = 1 AND @fw_new IS NULL AND @fw_old IS NOT NULL
        UPDATE grac_practice.asset_firmware_installation SET is_current = 0 WHERE asset_id = @out_asset_id AND is_current = 1;
    IF @os_on_tpl = 1 AND @os_new IS NOT NULL AND (ISNULL(@os_old, -1) <> @os_new OR ISNULL(@patch_old, N'') <> ISNULL(@patch_new, N''))
    BEGIN
        EXEC grac_practice.sp_asset_tech_install_apply
             @organization_id = @organization_id, @asset_id = @out_asset_id, @kind = N'OS', @release_id = @os_new,
             @build_patch_level = @patch_new, @installed_date = @today, @source = @form_source, @update_value = 0,
             @actor = @actor, @out_installation_id = @inst_id OUTPUT;
    END
    ELSE IF @os_on_tpl = 1 AND @os_new IS NULL AND @os_old IS NOT NULL
        UPDATE grac_practice.asset_os_installation SET is_current = 0 WHERE asset_id = @out_asset_id AND is_current = 1;

    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-register', @out_asset_id, CASE WHEN @asset_id IS NULL THEN N'ADD' ELSE N'SAVE' END,
            CASE WHEN @asset_id IS NULL THEN NULL ELSE @before END,
            (SELECT @template_id AS templateId,
                    (SELECT e.field_key AS fieldKey, e.val AS value FROM @eff e WHERE e.submitted = 1 FOR JSON PATH) AS changedValues
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            N'Active', @actor);
    COMMIT;

    SET @out_result = N'SAVED';
    SELECT severity AS Severity, field_key AS FieldKey, message AS Message FROM @issues ORDER BY field_key;
END
GO
PRINT '430: sp_asset_register_save re-issued.';
GO

-- =====================================================================
-- 5. Technology tab writes
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_tech_install_record
    @organization_id         BIGINT,
    @asset_id                BIGINT,
    @kind                    NVARCHAR(10),
    @release_id              BIGINT,
    @installed_date          DATE           = NULL,
    @source                  NVARCHAR(100)  = NULL,
    @result                  NVARCHAR(20)   = NULL,
    @build_patch_level       NVARCHAR(100)  = NULL,
    @rollback_note           NVARCHAR(1000) = NULL,
    @licence_reference       NVARCHAR(400)  = NULL,
    @evidence_text           NVARCHAR(1000) = NULL,
    @expected_record_version BIGINT         = NULL,
    @actor_employee_id       BIGINT         = NULL,
    @actor                   NVARCHAR(100)  = N'system',
    @out_installation_id     BIGINT         = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    SET @kind = UPPER(LTRIM(RTRIM(ISNULL(@kind, N''))));
    SET @source = NULLIF(LTRIM(RTRIM(@source)), N'');
    SET @result = UPPER(NULLIF(LTRIM(RTRIM(@result)), N''));
    SET @build_patch_level = NULLIF(LTRIM(RTRIM(@build_patch_level)), N'');
    SET @rollback_note = NULLIF(LTRIM(RTRIM(@rollback_note)), N'');
    SET @licence_reference = NULLIF(LTRIM(RTRIM(@licence_reference)), N'');
    SET @evidence_text = NULLIF(LTRIM(RTRIM(@evidence_text)), N'');

    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 54320, 'Organization not found.', 1;
    DECLARE @found BIT = 0, @rv BIGINT, @type_id INT;
    SELECT @found = 1, @rv = CONVERT(BIGINT, record_version), @type_id = asset_type_id
      FROM grac_practice.organization_dependency_asset WHERE asset_id = @asset_id AND organization_id = @organization_id;
    IF @found = 0 THROW 54321, 'Asset not found for this organization.', 1;
    IF @expected_record_version IS NOT NULL AND @expected_record_version <> @rv
        THROW 54322, 'This asset was changed by someone else. Reload it and try again.', 1;
    IF @kind NOT IN (N'FIRMWARE', N'OS')
        THROW 54323, 'Technology must be FIRMWARE or OS.', 1;

    -- Release: visible to the organization and usable (firmware not Draft / Withdrawn, OS not Draft).
    IF (@kind = N'FIRMWARE' AND NOT EXISTS (
            SELECT 1 FROM grac_practice.asset_firmware_release r
              JOIN grac_practice.entity_status_master s ON s.entity_status_id = r.current_status_id
             WHERE r.release_id = @release_id AND (r.organization_id IS NULL OR r.organization_id = @organization_id)
               AND s.status_code NOT IN (N'DRAFT', N'WITHDRAWN')))
       OR (@kind = N'OS' AND NOT EXISTS (
            SELECT 1 FROM grac_practice.asset_os_release r
              JOIN grac_practice.entity_status_master s ON s.entity_status_id = r.current_status_id
             WHERE r.release_id = @release_id AND (r.organization_id IS NULL OR r.organization_id = @organization_id)
               AND s.status_code <> N'DRAFT'))
        THROW 54324, 'Select a catalogue release that is approved and available to this organization.', 1;
    IF @installed_date IS NULL OR @installed_date > CAST(SYSUTCDATETIME() AS DATE)
        THROW 54325, 'Enter the installed date; it cannot be in the future.', 1;
    IF @source IS NULL
        THROW 54326, 'Enter the source of the installation (manual, discovery, import, vendor ...).', 1;
    IF @kind = N'FIRMWARE'
    BEGIN
        SET @result = ISNULL(@result, N'SUCCESSFUL');
        IF @result NOT IN (N'SUCCESSFUL', N'FAILED')
            THROW 54327, 'Result must be Successful or Failed.', 1;
    END
    ELSE
        SET @result = N'SUCCESSFUL';    -- BRD 4.6 lists no result for an OS installation

    -- 5.1.16 / 4.8: a version that becomes current needs an approved mapping or an active exception.
    DECLARE @model_id BIGINT = (SELECT TOP 1 v.value_ref FROM grac_practice.asset_field_value v
                                  JOIN grac_practice.asset_field_definition d ON d.field_definition_id = v.field_definition_id AND d.field_key = N'model'
                                 WHERE v.asset_id = @asset_id);
    DECLARE @hw_rev NVARCHAR(400) = (SELECT TOP 1 v.value_text FROM grac_practice.asset_field_value v
                                       JOIN grac_practice.asset_field_definition d ON d.field_definition_id = v.field_definition_id AND d.field_key = N'hardware_revision'
                                      WHERE v.asset_id = @asset_id);
    IF @result = N'SUCCESSFUL' AND @model_id IS NOT NULL
       AND grac_practice.fn_asset_tech_compatible(@organization_id, @kind, @release_id, @type_id, @model_id,
                                                  CASE WHEN @kind = N'FIRMWARE' THEN @hw_rev END) = 0
       AND NOT EXISTS (SELECT 1 FROM grac_practice.fn_asset_tech_exception_active(@organization_id, @asset_id, @model_id, @kind, @release_id))
        THROW 54328, 'This version has no approved compatibility record for the asset''s model and no active technology exception covers it.', 1;

    BEGIN TRAN;
    EXEC grac_practice.sp_asset_tech_install_apply
         @organization_id = @organization_id, @asset_id = @asset_id, @kind = @kind, @release_id = @release_id,
         @build_patch_level = @build_patch_level, @installed_date = @installed_date, @source = @source, @result = @result,
         @rollback_note = @rollback_note, @licence_reference = @licence_reference, @evidence_text = @evidence_text,
         @update_value = 1, @actor = @actor, @out_installation_id = @out_installation_id OUTPUT;
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-technology', @asset_id, N'INSTALLATION', NULL,
            (SELECT @kind AS kind, @release_id AS releaseId, @installed_date AS installedDate, @source AS source, @result AS result,
                    @build_patch_level AS buildPatchLevel, @rollback_note AS rollbackNote, @licence_reference AS licence,
                    @evidence_text AS evidence, @out_installation_id AS installationId
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            N'Active', @actor);
    COMMIT;

    SELECT @out_installation_id AS InstallationId;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_asset_tech_exception_request
    @organization_id     BIGINT,
    @asset_id            BIGINT,
    @scope               NVARCHAR(10),          -- ASSET | MODEL (every asset of this assets model)
    @kind                NVARCHAR(10),
    @release_id          BIGINT,
    @reason              NVARCHAR(1000) = NULL,
    @controls            NVARCHAR(1000) = NULL,
    @owner_employee_id   BIGINT         = NULL,
    @expiry_date         DATE           = NULL,
    @review_date         DATE           = NULL,
    @actor_employee_id   BIGINT         = NULL,
    @actor               NVARCHAR(100)  = N'system',
    @out_exception_id    BIGINT         = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    SET @scope = UPPER(LTRIM(RTRIM(ISNULL(@scope, N''))));
    SET @kind = UPPER(LTRIM(RTRIM(ISNULL(@kind, N''))));
    SET @reason = NULLIF(LTRIM(RTRIM(@reason)), N'');
    SET @controls = NULLIF(LTRIM(RTRIM(@controls)), N'');
    DECLARE @today DATE = CAST(SYSUTCDATETIME() AS DATE);

    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 54320, 'Organization not found.', 1;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization_dependency_asset WHERE asset_id = @asset_id AND organization_id = @organization_id)
        THROW 54321, 'Asset not found for this organization.', 1;
    IF @kind NOT IN (N'FIRMWARE', N'OS')
        THROW 54323, 'Technology must be FIRMWARE or OS.', 1;
    IF @scope NOT IN (N'ASSET', N'MODEL')
        THROW 54330, 'The exception applies to this asset (ASSET) or to every asset of its model (MODEL).', 1;
    DECLARE @model_id BIGINT = (SELECT TOP 1 v.value_ref FROM grac_practice.asset_field_value v
                                  JOIN grac_practice.asset_field_definition d ON d.field_definition_id = v.field_definition_id AND d.field_key = N'model'
                                 WHERE v.asset_id = @asset_id);
    IF @scope = N'MODEL' AND @model_id IS NULL
        THROW 54342, 'The asset has no model; a model-wide exception needs one.', 1;
    IF (@kind = N'FIRMWARE' AND NOT EXISTS (
            SELECT 1 FROM grac_practice.asset_firmware_release r
              JOIN grac_practice.entity_status_master s ON s.entity_status_id = r.current_status_id
             WHERE r.release_id = @release_id AND (r.organization_id IS NULL OR r.organization_id = @organization_id) AND s.status_code <> N'DRAFT'))
       OR (@kind = N'OS' AND NOT EXISTS (
            SELECT 1 FROM grac_practice.asset_os_release r
              JOIN grac_practice.entity_status_master s ON s.entity_status_id = r.current_status_id
             WHERE r.release_id = @release_id AND (r.organization_id IS NULL OR r.organization_id = @organization_id) AND s.status_code <> N'DRAFT'))
        THROW 54324, 'Select a catalogue release available to this organization.', 1;
    IF @reason IS NULL OR @controls IS NULL
        THROW 54331, 'Enter the reason and the compensating controls.', 1;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee
                    WHERE employee_id = @owner_employee_id AND organization_id = @organization_id AND status = N'Active')
        THROW 54332, 'Select an active owner from this organization.', 1;
    IF @expiry_date IS NULL OR @expiry_date <= @today
        THROW 54333, 'The expiry date must be after today.', 1;
    IF @review_date IS NOT NULL AND (@review_date < @today OR @review_date > @expiry_date)
        THROW 54333, 'The review date must be between today and the expiry date.', 1;

    DECLARE @scope_asset BIGINT = CASE WHEN @scope = N'ASSET' THEN @asset_id END;
    DECLARE @fw BIGINT = CASE WHEN @kind = N'FIRMWARE' THEN @release_id END,
            @os BIGINT = CASE WHEN @kind = N'OS' THEN @release_id END;
    IF EXISTS (SELECT 1 FROM grac_practice.asset_technology_exception e
                WHERE e.organization_id = @organization_id AND e.technology_kind = @kind
                  AND ISNULL(e.firmware_release_id, -1) = ISNULL(@fw, -1) AND ISNULL(e.os_release_id, -1) = ISNULL(@os, -1)
                  AND ISNULL(e.asset_id, -1) = ISNULL(@scope_asset, -1)
                  AND (@scope = N'ASSET' OR e.model_id = @model_id)
                  AND (e.status = N'PENDING_APPROVAL' OR (e.status = N'APPROVED' AND e.expiry_date >= @today)))
        THROW 54334, 'An exception for this version and scope is already awaiting approval or active.', 1;

    BEGIN TRAN;
    INSERT grac_practice.asset_technology_exception
        (organization_id, technology_kind, asset_id, model_id, firmware_release_id, os_release_id, reason, compensating_controls,
         owner_employee_id, expiry_date, review_date, status, requested_by, requested_by_employee_id)
    VALUES (@organization_id, @kind, @scope_asset, @model_id, @fw, @os, @reason, @controls,
            @owner_employee_id, @expiry_date, @review_date, N'PENDING_APPROVAL', @actor, @actor_employee_id);
    SET @out_exception_id = SCOPE_IDENTITY();
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-technology-exception', @out_exception_id, N'REQUEST', NULL,
            (SELECT @asset_id AS assetId, @scope AS scope, @model_id AS modelId, @kind AS kind, @release_id AS releaseId,
                    @reason AS reason, @controls AS controls, @owner_employee_id AS ownerEmployeeId,
                    @expiry_date AS expiryDate, @review_date AS reviewDate FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            N'Active', @actor);
    COMMIT;

    SELECT @out_exception_id AS ExceptionId, N'PENDING_APPROVAL' AS Result;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_asset_tech_exception_decide
    @organization_id         BIGINT,
    @exception_id            BIGINT,
    @decision                NVARCHAR(10),       -- APPROVE | REJECT | WITHDRAW | REVOKE
    @decision_note           NVARCHAR(1000) = NULL,
    @expected_record_version BIGINT         = NULL,
    @actor_employee_id       BIGINT         = NULL,
    @actor                   NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    SET @decision = UPPER(LTRIM(RTRIM(ISNULL(@decision, N''))));
    SET @decision_note = NULLIF(LTRIM(RTRIM(@decision_note)), N'');

    DECLARE @found BIT = 0, @status NVARCHAR(20), @rv BIGINT, @req_by NVARCHAR(100), @req_emp BIGINT, @expiry DATE;
    SELECT @found = 1, @status = status, @rv = CONVERT(BIGINT, record_version), @req_by = requested_by,
           @req_emp = requested_by_employee_id, @expiry = expiry_date
      FROM grac_practice.asset_technology_exception
     WHERE exception_id = @exception_id AND organization_id = @organization_id;
    IF @found = 0 THROW 54335, 'Technology exception not found for this organization.', 1;
    IF @decision NOT IN (N'APPROVE', N'REJECT', N'WITHDRAW', N'REVOKE')
        THROW 54341, 'The decision must be Approve, Reject, Withdraw or Revoke.', 1;
    IF @expected_record_version IS NOT NULL AND @expected_record_version <> @rv
        THROW 54340, 'This exception was changed by someone else. Reload and try again.', 1;
    IF (@decision IN (N'APPROVE', N'REJECT', N'WITHDRAW') AND @status <> N'PENDING_APPROVAL')
       OR (@decision = N'REVOKE' AND @status <> N'APPROVED')
        THROW 54336, 'This exception is not in a state that allows that decision.', 1;
    IF @decision = N'WITHDRAW' AND @req_by <> @actor
        THROW 54339, 'Only the person who requested this exception can withdraw it.', 1;
    IF @decision IN (N'APPROVE', N'REJECT')
       AND (@req_by = @actor OR (@req_emp IS NOT NULL AND @req_emp = @actor_employee_id))
        THROW 54337, 'Segregation of duties: the person who requested this exception cannot approve or reject it.', 1;
    IF @decision IN (N'REJECT', N'REVOKE') AND @decision_note IS NULL
        THROW 54338, 'Give the reason for this decision.', 1;
    IF @decision = N'APPROVE' AND @expiry <= CAST(SYSUTCDATETIME() AS DATE)
        THROW 54333, 'The expiry date has passed. Reject this request and raise a new one.', 1;

    DECLARE @new_status NVARCHAR(20) = CASE @decision WHEN N'APPROVE' THEN N'APPROVED' WHEN N'REJECT' THEN N'REJECTED'
                                                      WHEN N'WITHDRAW' THEN N'WITHDRAWN' ELSE N'REVOKED' END;
    BEGIN TRAN;
    UPDATE grac_practice.asset_technology_exception
       SET status = @new_status, decided_by = @actor, decided_by_employee_id = @actor_employee_id,
           decided_dt = SYSUTCDATETIME(), decision_note = @decision_note
     WHERE exception_id = @exception_id;
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-technology-exception', @exception_id, @decision,
            (SELECT @status AS status FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            (SELECT @new_status AS status, @decision_note AS note FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            N'Active', @actor);
    COMMIT;

    SELECT @exception_id AS ExceptionId, @new_status AS Result;
END
GO

-- =====================================================================
-- 6. Reader: 1. status per technology  2. firmware history
--            3. OS history  4. exceptions for the asset and its model
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_technology_get
    @organization_id BIGINT,
    @asset_id        BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization_dependency_asset WHERE asset_id = @asset_id AND organization_id = @organization_id)
        THROW 54321, 'Asset not found for this organization.', 1;

    SELECT st.*, CONVERT(BIGINT, a.record_version) AS RecordVersion
      FROM grac_practice.fn_asset_technology_status(@organization_id, @asset_id) st
      JOIN grac_practice.organization_dependency_asset a ON a.asset_id = st.AssetId
     ORDER BY CASE st.Kind WHEN N'FIRMWARE' THEN 0 ELSE 1 END;

    SELECT i.installation_id AS InstallationId, i.release_id AS ReleaseId,
           grac_practice.fn_asset_fw_release_label(i.release_id) AS ReleaseLabel,
           grac_practice.fn_asset_fw_release_label(i.previous_release_id) AS PreviousLabel,
           i.installed_date AS InstalledDate, i.source AS Source, i.result AS Result, i.rollback_note AS RollbackNote,
           i.evidence_text AS EvidenceText, i.is_current AS IsCurrent, i.entered_by AS EnteredBy, i.entered_dt AS EnteredDt
      FROM grac_practice.asset_firmware_installation i
     WHERE i.asset_id = @asset_id
     ORDER BY i.entered_dt DESC, i.installation_id DESC;

    SELECT i.installation_id AS InstallationId, i.release_id AS ReleaseId,
           grac_practice.fn_asset_os_release_label(i.release_id) AS ReleaseLabel, i.build_patch_level AS BuildPatchLevel,
           grac_practice.fn_asset_os_release_label(i.previous_release_id) AS PreviousLabel,
           i.previous_build_patch_level AS PreviousBuildPatchLevel,
           i.installed_date AS InstalledDate, i.source AS Source, i.licence_reference AS LicenceReference,
           i.evidence_text AS EvidenceText, i.is_current AS IsCurrent, i.entered_by AS EnteredBy, i.entered_dt AS EnteredDt
      FROM grac_practice.asset_os_installation i
     WHERE i.asset_id = @asset_id
     ORDER BY i.entered_dt DESC, i.installation_id DESC;

    DECLARE @model_id BIGINT = (SELECT TOP 1 v.value_ref FROM grac_practice.asset_field_value v
                                  JOIN grac_practice.asset_field_definition d ON d.field_definition_id = v.field_definition_id AND d.field_key = N'model'
                                 WHERE v.asset_id = @asset_id);
    SELECT e.exception_id AS ExceptionId, e.technology_kind AS Kind,
           CASE WHEN e.asset_id IS NULL THEN N'MODEL' ELSE N'ASSET' END AS Scope,
           CASE WHEN e.technology_kind = N'FIRMWARE' THEN grac_practice.fn_asset_fw_release_label(e.firmware_release_id)
                ELSE grac_practice.fn_asset_os_release_label(e.os_release_id) END AS ReleaseLabel,
           m.model_name AS ModelName, e.reason AS Reason, e.compensating_controls AS CompensatingControls,
           e.owner_employee_id AS OwnerEmployeeId, ow.employee_name AS OwnerName,
           e.expiry_date AS ExpiryDate, e.review_date AS ReviewDate, e.status AS Status,
           CASE WHEN e.status = N'APPROVED' AND e.expiry_date < CAST(SYSUTCDATETIME() AS DATE) THEN N'EXPIRED' ELSE e.status END AS DisplayStatus,
           e.requested_by AS RequestedBy, re.employee_name AS RequestedByName, e.requested_dt AS RequestedDt,
           e.decided_by AS DecidedBy, de.employee_name AS DecidedByName, e.decided_dt AS DecidedDt, e.decision_note AS DecisionNote,
           CONVERT(BIGINT, e.record_version) AS RecordVersion
      FROM grac_practice.asset_technology_exception e
      LEFT JOIN grac_practice.asset_model m ON m.model_id = e.model_id
      LEFT JOIN grac_practice.organization_employee ow ON ow.employee_id = e.owner_employee_id
      LEFT JOIN grac_practice.organization_employee re ON re.employee_id = e.requested_by_employee_id
      LEFT JOIN grac_practice.organization_employee de ON de.employee_id = e.decided_by_employee_id
     WHERE e.organization_id = @organization_id
       AND (e.asset_id = @asset_id OR (e.asset_id IS NULL AND e.model_id = @model_id))
     ORDER BY e.requested_dt DESC, e.exception_id DESC;
END
GO
PRINT '430: technology procedures created.';
GO

-- =====================================================================
-- Verification
-- =====================================================================
SELECT '430-a history and exception tables with one-current / one-pending indexes' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.asset_firmware_installation','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.asset_os_installation','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.asset_technology_exception','U') IS NOT NULL
             AND (SELECT COUNT(*) FROM sys.indexes WHERE name IN ('ux_pm_asset_fw_install_current', 'ux_pm_asset_os_install_current',
                                                                   'ux_pm_asset_tech_exc_pending')) = 3
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '430-b every firmware / OS value on an asset has a current history row',
       CASE WHEN NOT EXISTS (SELECT 1 FROM grac_practice.asset_field_value v
                               JOIN grac_practice.asset_field_definition d ON d.field_definition_id = v.field_definition_id AND d.field_key = N'firmware_version'
                              WHERE v.value_ref IS NOT NULL
                                AND NOT EXISTS (SELECT 1 FROM grac_practice.asset_firmware_installation i WHERE i.asset_id = v.asset_id AND i.is_current = 1))
             AND NOT EXISTS (SELECT 1 FROM grac_practice.asset_field_value v
                               JOIN grac_practice.asset_field_definition d ON d.field_definition_id = v.field_definition_id AND d.field_key = N'operating_system'
                              WHERE v.value_ref IS NOT NULL
                                AND NOT EXISTS (SELECT 1 FROM grac_practice.asset_os_installation i WHERE i.asset_id = v.asset_id AND i.is_current = 1))
            THEN 'PASS' ELSE 'CHECK -- a value points to a release that is not in the catalogue' END
UNION ALL
SELECT '430-c save re-issued with the exception rule and the history write',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_asset_register_save')) LIKE '%fn_asset_tech_exception_active%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_asset_register_save')) LIKE '%sp_asset_tech_install_apply%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '430-d functions and procedures present',
       CASE WHEN OBJECT_ID('grac_practice.fn_asset_tech_compatible') IS NOT NULL
             AND OBJECT_ID('grac_practice.fn_asset_tech_exception_active') IS NOT NULL
             AND OBJECT_ID('grac_practice.fn_asset_technology_status') IS NOT NULL
             AND (SELECT COUNT(*) FROM sys.procedures WHERE SCHEMA_NAME(schema_id) = 'grac_practice'
                   AND name IN ('sp_asset_tech_install_apply', 'sp_asset_tech_install_record', 'sp_asset_tech_exception_request',
                                'sp_asset_tech_exception_decide', 'sp_asset_technology_get')) = 5
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '430-e status function returns two rows per asset',
       CASE WHEN NOT EXISTS (SELECT 1 FROM grac_practice.organization_dependency_asset a
                              WHERE (SELECT COUNT(*) FROM grac_practice.fn_asset_technology_status(a.organization_id, a.asset_id)) <> 2)
            THEN 'PASS' ELSE 'FAIL' END;
GO

-- =====================================================================
-- UAT (after deploying the API + Web build)
--   Needs a model with approved firmware / OS compatibility (Technology
--   Catalogue) and an asset of that model whose form has the Firmware
--   version / Operating system fields.
--   1. Asset Register -> asset -> Technology: firmware and OS rows show
--      the current version (or Unknown), release status, support dates,
--      classification and the recommended target (a Recommended firmware
--      release / approved-baseline OS approved for the model).
--   2. Record firmware installation of a compatible release: history row,
--      previous version filled, the form s Firmware version follows. A
--      Failed result is kept as history and the current version stays.
--   3. Record (or pick on the form) a release with no approved mapping for
--      the model -- refused. Request a technology exception for it (this
--      asset or the whole model) -- the same user cannot approve; another
--      user with APPROVE approves -- now the installation is accepted and
--      the row shows Exception until the expiry date.
--   4. Change Operating system / patch level on the form and save -- an OS
--      history row with source "Asset form".
--   5. Revoke the exception (note required) -- the asset shows Unsupported.
-- =====================================================================
