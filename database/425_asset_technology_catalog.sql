-- =====================================================================
-- 425  Technology catalogue: asset makes and models
--      (Asset & Contract Management, Phase 3 increment 1)
--
-- REQUEST
-- -------
--   BRD v1.7 4.2 (Asset Make Master), 4.3 (Asset Model Master and
--   Lifecycle), 4.6 TechnologyLifecycleEvent, 4.7 steps 1-2 (create,
--   validate required fields, date sequence, duplicates, source
--   evidence) and 4.8 ("lifecycle dates cannot be overwritten without
--   reason and history", "end-of-support dates cannot precede release
--   dates"). The field dictionary already names MASTER:MAKE and
--   MASTER:MODEL (420); this migration creates those masters.
--   Firmware (4.4), operating systems (4.5), compatibility and installed
--   history follow in the next increments. Plan in
--   docs/asset-contract-management.md.
--
-- WHAT THIS DOES
-- --------------
--   1. asset_make -- identity (name, legal name, aliases), support
--      (portals, contact, region), governance (owner, authoritative
--      source, verified date / by, effective date, version number that
--      rises on every save), status Active / Inactive.
--      asset_make_asset_type -- "supported asset types" (4.2).
--   2. asset_model -- identity (name, number, make, asset type, family /
--      series, variant, SKU), release and support dates (announcement,
--      general availability, end of sale, end of standard / security /
--      extended support, end of life), technical (architecture, hardware
--      revision, specifications), governance (source / document URL,
--      verified date / by, approval), risk (criticality, replacement lead
--      time, lifecycle risk, controls) and the BRD lifecycle status
--      Planned / Current / Legacy / Approaching EOS / Unsupported /
--      Retired (set by the catalogue administrator; the BRD gives no rule
--      to derive it).
--   3. Record approval for models (state-machine framework, entity
--      AssetModel): Draft -> Pending Approval -> Approved; Pending ->
--      Draft (return, reason); Approved -> Withdrawn (reason); Draft ->
--      Withdrawn (discard, reason); Withdrawn -> Draft (reopen, reason).
--      Submitting needs the source / document reference ("source
--      evidence", 4.7 step 2). The submitter cannot approve.
--      Once approved, the identity of a model (make, asset type, name,
--      number, variant, hardware revision) is locked; dates, status,
--      governance and risk stay editable.
--   4. technology_lifecycle_event -- one row per changed milestone (the
--      seven dates and the lifecycle status) with before / after, source
--      and reason. Overwriting a milestone that already had a value needs
--      a reason (4.8). impact_count stays NULL until assets carry a model
--      (Phase 4).
--   5. Scope: organization_id NULL = shared catalogue row (platform
--      administrator only -- the Web proxy enforces it, the procedures
--      check the caller's declared scope matches the row); otherwise the
--      row belongs to that organization. An organization sees shared rows
--      plus its own; an organization model may use a shared make, a
--      shared model only a shared make.
--   6. Procedures: sp_asset_tech_catalog_list, sp_asset_model_get,
--      sp_asset_make_save, sp_asset_model_save, sp_asset_model_transition.
--   7. Menu "Technology Catalogue" (asset-tech-catalog) under Asset &
--      Contract; Admin grant VIEW / ADD / EDIT / APPROVE.
--
-- DUPLICATE RULES (4.7 step 2)
--   Make: the name may not equal another visible make's name or alias.
--   Model: per make, the model number is unique when given, and name +
--   variant + hardware revision is unique.
-- DATE RULES (4.8): each end date (end of sale, end of standard /
--   security / extended support, end of life) on or after the general
--   availability date; announcement on or before it. No other ordering
--   is enforced -- the BRD states none.
--
-- NOT DONE HERE: firmware / OS catalogues and compatibility (next
--   increments); blocking asset creation for Legacy / Unsupported /
--   Retired models (4.3 -- the Asset Register, Phase 4); extended
--   commercial support records (4.3 -- with contracts, Phase 5); impact
--   analysis and refresh campaigns (4.7 steps 4-8).
--
-- ERROR NUMBERS: 54800-54849
--   54800 organization not found         54801 make not found
--   54802 make name required             54803 make name already used
--   54804 shared-catalogue scope mismatch 54805 changed by someone else
--   54806 asset type not valid           54807 model not found
--   54808 model name required            54809 duplicate model
--   54810 make not usable for this model 54811 date sequence
--   54812 reason required (milestone overwrite) 54813 identity locked
--   54814 lifecycle status not valid     54815 not ready to submit
--   54816 segregation of duties          54817 reason required (move)
--   54818 criticality not valid
--
-- ALSO EDITED: 274_menu_master_seed.sql, API (AssetConfig service /
--   controller / models), Web proxy, PracticeScreen.cs, Manage.cshtml,
--   new partial + script asset-tech-catalog, both appsettings.json.
-- DEPENDS ON: 035, 420, 424.
-- Rollback: 425_asset_technology_catalog_rollback.sql
-- Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.fn_asset_taxonomy_selectable') IS NULL
   OR OBJECT_ID('grac_practice.fn_asset_make_code') IS NULL
   OR OBJECT_ID('grac_practice.sp_pm_state_transition','P') IS NULL
   OR OBJECT_ID('grac_practice.entity_status_master','U') IS NULL
   OR OBJECT_ID('grac_practice.criticality_master','U') IS NULL
BEGIN
    RAISERROR('ABORT (425): run 035, 420 and 424 first.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. Tables
-- =====================================================================
IF OBJECT_ID('grac_practice.asset_make','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_make (
        make_id               INT            IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_asset_make PRIMARY KEY,
        organization_id       BIGINT         NULL
            CONSTRAINT fk_pm_asset_make_org REFERENCES grac_practice.organization(organization_id),
        make_code             NVARCHAR(80)   NOT NULL CONSTRAINT uq_pm_asset_make_code UNIQUE,
        make_name             NVARCHAR(200)  NOT NULL,
        legal_name            NVARCHAR(300)  NULL,
        aliases               NVARCHAR(1000) NULL,
        support_portal_url    NVARCHAR(500)  NULL,
        security_advisory_url NVARCHAR(500)  NULL,
        support_contact       NVARCHAR(300)  NULL,
        support_region        NVARCHAR(200)  NULL,
        owner_name            NVARCHAR(200)  NULL,
        authoritative_source  NVARCHAR(500)  NULL,
        verified_date         DATE           NULL,
        verified_by           NVARCHAR(200)  NULL,
        effective_date        DATE           NULL,
        version_no            INT            NOT NULL CONSTRAINT df_pm_asset_make_version DEFAULT 1,
        status                NVARCHAR(30)   NOT NULL CONSTRAINT df_pm_asset_make_status DEFAULT N'Active'
            CONSTRAINT ck_pm_asset_make_status CHECK (status IN (N'Active', N'Inactive')),
        entered_by            NVARCHAR(100)  NOT NULL CONSTRAINT df_pm_asset_make_eby DEFAULT N'system',
        entered_dt            DATETIME2      NOT NULL CONSTRAINT df_pm_asset_make_edt DEFAULT SYSUTCDATETIME(),
        updated_by            NVARCHAR(100)  NULL,
        updated_dt            DATETIME2      NULL,
        record_version        ROWVERSION     NOT NULL
    );
    CREATE INDEX ix_pm_asset_make_org ON grac_practice.asset_make(organization_id, make_name);
    PRINT '425: asset_make created.';
END
GO

IF OBJECT_ID('grac_practice.asset_make_asset_type','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_make_asset_type (
        make_id       INT           NOT NULL
            CONSTRAINT fk_pm_asset_make_type_make REFERENCES grac_practice.asset_make(make_id),
        asset_type_id INT           NOT NULL
            CONSTRAINT fk_pm_asset_make_type_type REFERENCES grac_practice.dependency_asset_type_master(asset_type_id),
        entered_by    NVARCHAR(100) NOT NULL CONSTRAINT df_pm_asset_make_type_eby DEFAULT N'system',
        entered_dt    DATETIME2     NOT NULL CONSTRAINT df_pm_asset_make_type_edt DEFAULT SYSUTCDATETIME(),
        CONSTRAINT pk_pm_asset_make_asset_type PRIMARY KEY (make_id, asset_type_id)
    );
    PRINT '425: asset_make_asset_type created.';
END
GO

IF OBJECT_ID('grac_practice.asset_model','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_model (
        model_id                   BIGINT         IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_asset_model PRIMARY KEY,
        organization_id            BIGINT         NULL
            CONSTRAINT fk_pm_asset_model_org REFERENCES grac_practice.organization(organization_id),
        make_id                    INT            NOT NULL
            CONSTRAINT fk_pm_asset_model_make REFERENCES grac_practice.asset_make(make_id),
        asset_type_id              INT            NOT NULL
            CONSTRAINT fk_pm_asset_model_type REFERENCES grac_practice.dependency_asset_type_master(asset_type_id),
        model_code                 NVARCHAR(100)  NOT NULL CONSTRAINT uq_pm_asset_model_code UNIQUE,
        model_name                 NVARCHAR(200)  NOT NULL,
        model_number               NVARCHAR(120)  NULL,
        family_series              NVARCHAR(200)  NULL,
        variant                    NVARCHAR(120)  NULL,
        sku                        NVARCHAR(120)  NULL,
        announcement_date          DATE           NULL,
        release_date               DATE           NULL,
        end_of_sale_date           DATE           NULL,
        end_standard_support_date  DATE           NULL,
        end_security_support_date  DATE           NULL,
        end_extended_support_date  DATE           NULL,
        end_of_life_date           DATE           NULL,
        architecture               NVARCHAR(120)  NULL,
        hardware_revision          NVARCHAR(120)  NULL,
        specifications             NVARCHAR(MAX)  NULL,
        source_reference           NVARCHAR(500)  NULL,
        verified_date              DATE           NULL,
        verified_by                NVARCHAR(200)  NULL,
        criticality_id             INT            NULL
            CONSTRAINT fk_pm_asset_model_criticality REFERENCES grac_practice.criticality_master(criticality_id),
        replacement_lead_time_days INT            NULL
            CONSTRAINT ck_pm_asset_model_lead_time CHECK (replacement_lead_time_days IS NULL OR replacement_lead_time_days >= 0),
        lifecycle_risk             NVARCHAR(200)  NULL,
        controls                   NVARCHAR(1000) NULL,
        lifecycle_status           NVARCHAR(30)   NOT NULL CONSTRAINT df_pm_asset_model_lifecycle DEFAULT N'CURRENT'
            CONSTRAINT ck_pm_asset_model_lifecycle CHECK (lifecycle_status IN
                (N'PLANNED', N'CURRENT', N'LEGACY', N'APPROACHING_EOS', N'UNSUPPORTED', N'RETIRED')),
        current_status_id          INT            NOT NULL
            CONSTRAINT fk_pm_asset_model_status REFERENCES grac_practice.entity_status_master(entity_status_id),
        submitted_by               NVARCHAR(100)  NULL,
        submitted_dt               DATETIME2      NULL,
        approved_by                NVARCHAR(100)  NULL,
        approved_dt                DATETIME2      NULL,
        entered_by                 NVARCHAR(100)  NOT NULL CONSTRAINT df_pm_asset_model_eby DEFAULT N'system',
        entered_dt                 DATETIME2      NOT NULL CONSTRAINT df_pm_asset_model_edt DEFAULT SYSUTCDATETIME(),
        updated_by                 NVARCHAR(100)  NULL,
        updated_dt                 DATETIME2      NULL,
        record_version             ROWVERSION     NOT NULL,
        CONSTRAINT ck_pm_asset_model_dates CHECK (
            release_date IS NULL OR (
                (announcement_date         IS NULL OR announcement_date         <= release_date) AND
                (end_of_sale_date          IS NULL OR end_of_sale_date          >= release_date) AND
                (end_standard_support_date IS NULL OR end_standard_support_date >= release_date) AND
                (end_security_support_date IS NULL OR end_security_support_date >= release_date) AND
                (end_extended_support_date IS NULL OR end_extended_support_date >= release_date) AND
                (end_of_life_date          IS NULL OR end_of_life_date          >= release_date)))
    );
    CREATE INDEX ix_pm_asset_model_make ON grac_practice.asset_model(make_id, asset_type_id);
    CREATE INDEX ix_pm_asset_model_org  ON grac_practice.asset_model(organization_id);
    PRINT '425: asset_model created.';
END
GO

IF OBJECT_ID('grac_practice.technology_lifecycle_event','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.technology_lifecycle_event (
        event_id       BIGINT         IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_tech_lifecycle_event PRIMARY KEY,
        entity_type    NVARCHAR(30)   NOT NULL,   -- MODEL now; FIRMWARE / OS later
        entity_id      BIGINT         NOT NULL,
        milestone_code NVARCHAR(60)   NOT NULL,
        before_value   NVARCHAR(200)  NULL,
        after_value    NVARCHAR(200)  NULL,
        source         NVARCHAR(500)  NULL,
        reason         NVARCHAR(1000) NULL,
        impact_count   INT            NULL,       -- set once assets carry a model (Phase 4)
        entered_by     NVARCHAR(100)  NOT NULL CONSTRAINT df_pm_tech_lifecycle_event_eby DEFAULT N'system',
        entered_dt     DATETIME2      NOT NULL CONSTRAINT df_pm_tech_lifecycle_event_edt DEFAULT SYSUTCDATETIME()
    );
    CREATE INDEX ix_pm_tech_lifecycle_event_entity ON grac_practice.technology_lifecycle_event(entity_type, entity_id, entered_dt);
    PRINT '425: technology_lifecycle_event created.';
END
GO

-- =====================================================================
-- 2. Model record approval (state-machine framework)
-- =====================================================================
MERGE grac_practice.entity_status_master AS t
USING (VALUES
    (N'AssetModel', N'DRAFT',            N'Draft',            10, 0, 1, N'Being prepared; not offered for new assets.'),
    (N'AssetModel', N'PENDING_APPROVAL', N'Pending Approval', 20, 0, 0, N'Submitted for review and approval.'),
    (N'AssetModel', N'APPROVED',         N'Approved',         30, 0, 0, N'Approved catalogue model.'),
    (N'AssetModel', N'WITHDRAWN',        N'Withdrawn',        40, 0, 0, N'Withdrawn from the catalogue; kept for history.')
) AS s(entity_type, status_code, status_name, display_order, is_terminal, is_initial, description)
ON t.entity_type = s.entity_type AND t.status_code = s.status_code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (entity_type, status_code, status_name, display_order, is_terminal, is_initial, description, entered_by)
    VALUES (s.entity_type, s.status_code, s.status_name, s.display_order, s.is_terminal, s.is_initial, s.description, N'seed-425');
PRINT CONCAT('425: AssetModel statuses inserted: ', @@ROWCOUNT);
GO

MERGE grac_practice.entity_state_transition_rule AS t
USING (VALUES
    (CAST(NULL AS NVARCHAR(60)), N'DRAFT',     0, 0, N'Create a model.'),
    (N'DRAFT',            N'PENDING_APPROVAL', 0, 0, N'Submit for approval.'),
    (N'DRAFT',            N'WITHDRAWN',        1, 0, N'Discard a draft.'),
    (N'PENDING_APPROVAL', N'APPROVED',         0, 1, N'Approve the model.'),
    (N'PENDING_APPROVAL', N'DRAFT',            1, 0, N'Return to draft.'),
    (N'APPROVED',         N'WITHDRAWN',        1, 0, N'Withdraw an approved model.'),
    (N'WITHDRAWN',        N'DRAFT',            1, 0, N'Reopen a withdrawn model.')
) AS s(from_status_code, to_status_code, requires_reason, requires_approval, description)
ON t.entity_type = N'AssetModel'
   AND ISNULL(t.from_status_code, N'__NULL__') = ISNULL(s.from_status_code, N'__NULL__')
   AND t.to_status_code = s.to_status_code
   AND t.actor_role_code IS NULL
WHEN NOT MATCHED BY TARGET THEN
    INSERT (entity_type, from_status_code, to_status_code, actor_role_code, requires_reason, requires_approval, description, entered_by)
    VALUES (N'AssetModel', s.from_status_code, s.to_status_code, NULL, s.requires_reason, s.requires_approval, s.description, N'seed-425');
PRINT CONCAT('425: AssetModel transition rules inserted: ', @@ROWCOUNT);
GO

-- =====================================================================
-- 3. Readers
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_tech_catalog_list
    @organization_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 54800, 'Organization not found.', 1;

    -- 1. Makes visible to the organization (shared + its own)
    SELECT m.make_id AS MakeId, m.organization_id AS OrganizationId,
           CAST(CASE WHEN m.organization_id IS NULL THEN 1 ELSE 0 END AS BIT) AS IsShared,
           m.make_code AS MakeCode, m.make_name AS MakeName, m.legal_name AS LegalName, m.aliases AS Aliases,
           m.support_portal_url AS SupportPortalUrl, m.security_advisory_url AS SecurityAdvisoryUrl,
           m.support_contact AS SupportContact, m.support_region AS SupportRegion, m.owner_name AS OwnerName,
           m.authoritative_source AS AuthoritativeSource, m.verified_date AS VerifiedDate, m.verified_by AS VerifiedBy,
           m.effective_date AS EffectiveDate, m.version_no AS VersionNo, m.status AS Status,
           CONVERT(BIGINT, m.record_version) AS RecordVersion,
           (SELECT STRING_AGG(CAST(x.asset_type_id AS NVARCHAR(20)), N',') FROM grac_practice.asset_make_asset_type x
             WHERE x.make_id = m.make_id) AS AssetTypeIds,
           (SELECT COUNT(*) FROM grac_practice.asset_model d
             WHERE d.make_id = m.make_id AND (d.organization_id IS NULL OR d.organization_id = @organization_id)) AS ModelCount
      FROM grac_practice.asset_make m
     WHERE m.organization_id IS NULL OR m.organization_id = @organization_id
     ORDER BY m.make_name;

    -- 2. Models visible to the organization
    SELECT d.model_id AS ModelId, d.organization_id AS OrganizationId,
           CAST(CASE WHEN d.organization_id IS NULL THEN 1 ELSE 0 END AS BIT) AS IsShared,
           d.make_id AS MakeId, m.make_name AS MakeName, d.asset_type_id AS AssetTypeId, t.asset_type_name AS AssetTypeName,
           d.model_code AS ModelCode, d.model_name AS ModelName, d.model_number AS ModelNumber, d.variant AS Variant,
           d.hardware_revision AS HardwareRevision, d.lifecycle_status AS LifecycleStatus,
           d.release_date AS ReleaseDate, d.end_of_sale_date AS EndOfSaleDate,
           d.end_standard_support_date AS EndStandardSupportDate, d.end_of_life_date AS EndOfLifeDate,
           s.status_code AS StatusCode, s.status_name AS StatusName, CONVERT(BIGINT, d.record_version) AS RecordVersion
      FROM grac_practice.asset_model d
      JOIN grac_practice.asset_make m ON m.make_id = d.make_id
      JOIN grac_practice.dependency_asset_type_master t ON t.asset_type_id = d.asset_type_id
      JOIN grac_practice.entity_status_master s ON s.entity_status_id = d.current_status_id
     WHERE d.organization_id IS NULL OR d.organization_id = @organization_id
     ORDER BY m.make_name, d.model_name, d.variant;

    -- 3. Asset types that may be chosen now (424), with their path
    SELECT t.asset_type_id AS AssetTypeId, t.asset_type_name AS AssetTypeName,
           c.asset_category_name + N' / ' + ISNULL(p.subcategory_name + N' / ', N'') + s.subcategory_name AS Path
      FROM grac_practice.fn_asset_taxonomy_selectable() f
      JOIN grac_practice.dependency_asset_type_master t ON t.asset_type_id = f.NodeId
      JOIN grac_practice.dependency_asset_subcategory_master s ON s.subcategory_id = t.subcategory_id
      LEFT JOIN grac_practice.dependency_asset_subcategory_master p ON p.subcategory_id = s.parent_subcategory_id
      JOIN grac_practice.dependency_asset_category_master c ON c.asset_category_id = s.asset_category_id
     WHERE f.NodeKind = N'TYPE'
     ORDER BY c.display_order, s.display_order, t.display_order, t.asset_type_name;

    -- 4. Criticality values
    SELECT criticality_id AS CriticalityId, criticality_name AS CriticalityName
      FROM grac_practice.criticality_master WHERE is_active = 1 ORDER BY display_order, criticality_name;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_asset_model_get
    @organization_id BIGINT,
    @model_id        BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.asset_model
                    WHERE model_id = @model_id AND (organization_id IS NULL OR organization_id = @organization_id))
        THROW 54807, 'Model not found.', 1;

    -- 1. The model
    SELECT d.model_id AS ModelId, d.organization_id AS OrganizationId,
           CAST(CASE WHEN d.organization_id IS NULL THEN 1 ELSE 0 END AS BIT) AS IsShared,
           d.make_id AS MakeId, m.make_name AS MakeName, d.asset_type_id AS AssetTypeId, t.asset_type_name AS AssetTypeName,
           d.model_code AS ModelCode, d.model_name AS ModelName, d.model_number AS ModelNumber,
           d.family_series AS FamilySeries, d.variant AS Variant, d.sku AS Sku,
           d.announcement_date AS AnnouncementDate, d.release_date AS ReleaseDate, d.end_of_sale_date AS EndOfSaleDate,
           d.end_standard_support_date AS EndStandardSupportDate, d.end_security_support_date AS EndSecuritySupportDate,
           d.end_extended_support_date AS EndExtendedSupportDate, d.end_of_life_date AS EndOfLifeDate,
           d.architecture AS Architecture, d.hardware_revision AS HardwareRevision, d.specifications AS Specifications,
           d.source_reference AS SourceReference, d.verified_date AS VerifiedDate, d.verified_by AS VerifiedBy,
           d.criticality_id AS CriticalityId, d.replacement_lead_time_days AS ReplacementLeadTimeDays,
           d.lifecycle_risk AS LifecycleRisk, d.controls AS Controls, d.lifecycle_status AS LifecycleStatus,
           s.status_code AS StatusCode, s.status_name AS StatusName,
           d.submitted_by AS SubmittedBy, d.submitted_dt AS SubmittedDt, d.approved_by AS ApprovedBy, d.approved_dt AS ApprovedDt,
           CONVERT(BIGINT, d.record_version) AS RecordVersion
      FROM grac_practice.asset_model d
      JOIN grac_practice.asset_make m ON m.make_id = d.make_id
      JOIN grac_practice.dependency_asset_type_master t ON t.asset_type_id = d.asset_type_id
      JOIN grac_practice.entity_status_master s ON s.entity_status_id = d.current_status_id
     WHERE d.model_id = @model_id;

    -- 2. Lifecycle milestone history (4.6 TechnologyLifecycleEvent)
    SELECT e.event_id AS EventId, e.milestone_code AS MilestoneCode, e.before_value AS BeforeValue,
           e.after_value AS AfterValue, e.source AS Source, e.reason AS Reason, e.impact_count AS ImpactCount,
           e.entered_by AS EnteredBy, e.entered_dt AS EnteredDt
      FROM grac_practice.technology_lifecycle_event e
     WHERE e.entity_type = N'MODEL' AND e.entity_id = @model_id
     ORDER BY e.entered_dt DESC, e.event_id DESC;

    -- 3. Approval history
    SELECT l.transition_log_id AS TransitionLogId, fs.status_name AS FromStatus, ts.status_name AS ToStatus,
           l.actor_employee_id AS ActorEmployeeId, emp.employee_name AS ActorName,
           l.reason_code AS ReasonCode, l.reason_text AS ReasonText, l.transitioned_at AS TransitionedAt
      FROM grac_practice.entity_state_transition_log l
      LEFT JOIN grac_practice.entity_status_master fs ON fs.entity_status_id = l.from_status_id
      JOIN grac_practice.entity_status_master ts ON ts.entity_status_id = l.to_status_id
      LEFT JOIN grac_practice.organization_employee emp ON emp.employee_id = l.actor_employee_id
     WHERE l.entity_type = N'AssetModel' AND l.entity_id = @model_id
     ORDER BY l.transitioned_at DESC, l.transition_log_id DESC;
END
GO

-- =====================================================================
-- 4. Writers. @organization_id is the caller's organization context;
--    @shared = 1 declares a shared-catalogue change (the Web proxy only
--    lets the platform administrator send it). The procedures refuse
--    when the declared scope does not match the row (54804).
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_make_save
    @organization_id         BIGINT,
    @shared                  BIT            = 0,
    @make_id                 INT            = NULL,
    @make_name               NVARCHAR(200),
    @legal_name              NVARCHAR(300)  = NULL,
    @aliases                 NVARCHAR(1000) = NULL,
    @support_portal_url      NVARCHAR(500)  = NULL,
    @security_advisory_url   NVARCHAR(500)  = NULL,
    @support_contact         NVARCHAR(300)  = NULL,
    @support_region          NVARCHAR(200)  = NULL,
    @owner_name              NVARCHAR(200)  = NULL,
    @authoritative_source    NVARCHAR(500)  = NULL,
    @verified_date           DATE           = NULL,
    @verified_by             NVARCHAR(200)  = NULL,
    @effective_date          DATE           = NULL,
    @status                  NVARCHAR(30)   = N'Active',
    @asset_type_ids          NVARCHAR(MAX)  = NULL,   -- comma-separated; NULL leaves the mapping unchanged
    @expected_record_version BIGINT         = NULL,
    @actor                   NVARCHAR(100)  = N'system',
    @out_make_id             INT            = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    SET @shared = ISNULL(@shared, 0);
    SET @make_name = NULLIF(LTRIM(RTRIM(@make_name)), N'');
    SET @status = CASE WHEN @status = N'Inactive' THEN N'Inactive' ELSE N'Active' END;

    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 54800, 'Organization not found.', 1;
    DECLARE @scope_org BIGINT = CASE WHEN @shared = 1 THEN NULL ELSE @organization_id END;

    DECLARE @rv BIGINT, @row_org BIGINT, @found BIT = 0, @before NVARCHAR(MAX);
    IF @make_id IS NOT NULL
    BEGIN
        SELECT @found = 1, @rv = CONVERT(BIGINT, record_version), @row_org = organization_id
          FROM grac_practice.asset_make WHERE make_id = @make_id;
        IF @found = 0 OR (@row_org IS NOT NULL AND @row_org <> @organization_id)
            THROW 54801, 'Make not found.', 1;
        IF ISNULL(@row_org, -1) <> ISNULL(@scope_org, -1)
            THROW 54804, 'This make belongs to the shared catalogue; only the platform administrator can change it.', 1;
        IF @expected_record_version IS NOT NULL AND @expected_record_version <> @rv
            THROW 54805, 'This entry was changed by someone else. Reload and try again.', 1;
    END
    IF @make_name IS NULL THROW 54802, 'The make (manufacturer) name is required.', 1;

    -- Aliases: split on ; or , trim, de-duplicate, join with '; '.
    DECLARE @alias_list TABLE (alias NVARCHAR(200) PRIMARY KEY);
    INSERT @alias_list (alias)
    SELECT DISTINCT LEFT(LTRIM(RTRIM(value)), 200) FROM STRING_SPLIT(REPLACE(ISNULL(@aliases, N''), N',', N';'), N';')
     WHERE LTRIM(RTRIM(value)) <> N'' AND LTRIM(RTRIM(value)) <> @make_name;
    SET @aliases = (SELECT STRING_AGG(alias, N'; ') FROM @alias_list);

    -- Duplicates among the makes this scope can see (shared + the organization's).
    IF EXISTS (SELECT 1 FROM grac_practice.asset_make m
                WHERE m.make_id <> ISNULL(@make_id, -1)
                  AND (m.organization_id IS NULL OR m.organization_id = @organization_id)
                  AND (m.make_name = @make_name
                       OR N';' + REPLACE(ISNULL(m.aliases, N''), N'; ', N';') + N';' LIKE N'%;' + @make_name + N';%'
                       OR m.make_name IN (SELECT alias FROM @alias_list)))
        THROW 54803, 'Another make already uses this name or alias.', 1;

    -- Supported asset types: every id must be a known asset type.
    DECLARE @types TABLE (asset_type_id INT PRIMARY KEY);
    IF @asset_type_ids IS NOT NULL
    BEGIN
        INSERT @types (asset_type_id)
        SELECT DISTINCT TRY_CAST(LTRIM(RTRIM(value)) AS INT) FROM STRING_SPLIT(@asset_type_ids, N',')
         WHERE TRY_CAST(LTRIM(RTRIM(value)) AS INT) IS NOT NULL;
        IF EXISTS (SELECT 1 FROM @types x WHERE NOT EXISTS (
                     SELECT 1 FROM grac_practice.dependency_asset_type_master t WHERE t.asset_type_id = x.asset_type_id))
            THROW 54806, 'One of the supported asset types is not valid.', 1;
    END

    SET @before = (SELECT make_name AS makeName, legal_name AS legalName, aliases, support_portal_url AS supportPortalUrl,
                          security_advisory_url AS securityAdvisoryUrl, support_contact AS supportContact,
                          support_region AS supportRegion, owner_name AS ownerName, authoritative_source AS authoritativeSource,
                          verified_date AS verifiedDate, verified_by AS verifiedBy, effective_date AS effectiveDate,
                          version_no AS versionNo, status
                     FROM grac_practice.asset_make WHERE make_id = @make_id FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    BEGIN TRAN;
    IF @make_id IS NULL
    BEGIN
        DECLARE @base NVARCHAR(160) = N'MAKE_' + ISNULL(grac_practice.fn_asset_make_code(@make_name, 60), N'X'),
                @code NVARCHAR(160), @n INT = 1;
        SET @code = @base;
        WHILE EXISTS (SELECT 1 FROM grac_practice.asset_make WHERE make_code = @code)
        BEGIN
            SET @n = @n + 1;
            SET @code = @base + N'_' + CAST(@n AS NVARCHAR(10));
        END
        INSERT grac_practice.asset_make
            (organization_id, make_code, make_name, legal_name, aliases, support_portal_url, security_advisory_url,
             support_contact, support_region, owner_name, authoritative_source, verified_date, verified_by,
             effective_date, version_no, status, entered_by)
        VALUES (@scope_org, @code, @make_name, NULLIF(LTRIM(RTRIM(@legal_name)), N''), @aliases,
                NULLIF(LTRIM(RTRIM(@support_portal_url)), N''), NULLIF(LTRIM(RTRIM(@security_advisory_url)), N''),
                NULLIF(LTRIM(RTRIM(@support_contact)), N''), NULLIF(LTRIM(RTRIM(@support_region)), N''),
                NULLIF(LTRIM(RTRIM(@owner_name)), N''), NULLIF(LTRIM(RTRIM(@authoritative_source)), N''),
                @verified_date, NULLIF(LTRIM(RTRIM(@verified_by)), N''), @effective_date, 1, @status, @actor);
        SET @out_make_id = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        UPDATE grac_practice.asset_make
           SET make_name = @make_name, legal_name = NULLIF(LTRIM(RTRIM(@legal_name)), N''), aliases = @aliases,
               support_portal_url = NULLIF(LTRIM(RTRIM(@support_portal_url)), N''),
               security_advisory_url = NULLIF(LTRIM(RTRIM(@security_advisory_url)), N''),
               support_contact = NULLIF(LTRIM(RTRIM(@support_contact)), N''),
               support_region = NULLIF(LTRIM(RTRIM(@support_region)), N''),
               owner_name = NULLIF(LTRIM(RTRIM(@owner_name)), N''),
               authoritative_source = NULLIF(LTRIM(RTRIM(@authoritative_source)), N''),
               verified_date = @verified_date, verified_by = NULLIF(LTRIM(RTRIM(@verified_by)), N''),
               effective_date = @effective_date, status = @status, version_no = version_no + 1,
               updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE make_id = @make_id;
        SET @out_make_id = @make_id;
    END
    IF @asset_type_ids IS NOT NULL
    BEGIN
        DELETE grac_practice.asset_make_asset_type
         WHERE make_id = @out_make_id AND asset_type_id NOT IN (SELECT asset_type_id FROM @types);
        INSERT grac_practice.asset_make_asset_type (make_id, asset_type_id, entered_by)
        SELECT @out_make_id, x.asset_type_id, @actor FROM @types x
         WHERE NOT EXISTS (SELECT 1 FROM grac_practice.asset_make_asset_type e
                            WHERE e.make_id = @out_make_id AND e.asset_type_id = x.asset_type_id);
    END
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-make', @out_make_id, CASE WHEN @make_id IS NULL THEN N'ADD' ELSE N'SAVE' END, @before,
            (SELECT @scope_org AS organizationId, @make_name AS makeName, @legal_name AS legalName, @aliases AS aliases,
                    @support_portal_url AS supportPortalUrl, @security_advisory_url AS securityAdvisoryUrl,
                    @support_contact AS supportContact, @support_region AS supportRegion, @owner_name AS ownerName,
                    @authoritative_source AS authoritativeSource, @verified_date AS verifiedDate, @verified_by AS verifiedBy,
                    @effective_date AS effectiveDate, @status AS status, @asset_type_ids AS assetTypeIds
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            N'Active', @actor);
    COMMIT;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_asset_model_save
    @organization_id            BIGINT,
    @shared                     BIT            = 0,
    @model_id                   BIGINT         = NULL,
    @make_id                    INT,
    @asset_type_id              INT,
    @model_name                 NVARCHAR(200),
    @model_number               NVARCHAR(120)  = NULL,
    @family_series              NVARCHAR(200)  = NULL,
    @variant                    NVARCHAR(120)  = NULL,
    @sku                        NVARCHAR(120)  = NULL,
    @announcement_date          DATE           = NULL,
    @release_date               DATE           = NULL,
    @end_of_sale_date           DATE           = NULL,
    @end_standard_support_date  DATE           = NULL,
    @end_security_support_date  DATE           = NULL,
    @end_extended_support_date  DATE           = NULL,
    @end_of_life_date           DATE           = NULL,
    @architecture               NVARCHAR(120)  = NULL,
    @hardware_revision          NVARCHAR(120)  = NULL,
    @specifications             NVARCHAR(MAX)  = NULL,
    @source_reference           NVARCHAR(500)  = NULL,
    @verified_date              DATE           = NULL,
    @verified_by                NVARCHAR(200)  = NULL,
    @criticality_id             INT            = NULL,
    @replacement_lead_time_days INT            = NULL,
    @lifecycle_risk             NVARCHAR(200)  = NULL,
    @controls                   NVARCHAR(1000) = NULL,
    @lifecycle_status           NVARCHAR(30)   = N'CURRENT',
    @change_reason              NVARCHAR(1000) = NULL,
    @expected_record_version    BIGINT         = NULL,
    @actor_employee_id          BIGINT         = NULL,
    @actor                      NVARCHAR(100)  = N'system',
    @out_model_id               BIGINT         = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    SET @shared = ISNULL(@shared, 0);
    SET @model_name = NULLIF(LTRIM(RTRIM(@model_name)), N'');
    SET @model_number = NULLIF(LTRIM(RTRIM(@model_number)), N'');
    SET @variant = NULLIF(LTRIM(RTRIM(@variant)), N'');
    SET @hardware_revision = NULLIF(LTRIM(RTRIM(@hardware_revision)), N'');
    SET @change_reason = NULLIF(LTRIM(RTRIM(@change_reason)), N'');
    SET @source_reference = NULLIF(LTRIM(RTRIM(@source_reference)), N'');
    SET @lifecycle_status = UPPER(LTRIM(RTRIM(ISNULL(@lifecycle_status, N''))));

    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 54800, 'Organization not found.', 1;
    DECLARE @scope_org BIGINT = CASE WHEN @shared = 1 THEN NULL ELSE @organization_id END;

    DECLARE @old TABLE (
        organization_id BIGINT, make_id INT, asset_type_id INT, model_name NVARCHAR(200), model_number NVARCHAR(120),
        variant NVARCHAR(120), hardware_revision NVARCHAR(120), announcement_date DATE, release_date DATE,
        end_of_sale_date DATE, end_standard_support_date DATE, end_security_support_date DATE,
        end_extended_support_date DATE, end_of_life_date DATE, lifecycle_status NVARCHAR(30), status_code NVARCHAR(60),
        rv BIGINT);
    DECLARE @before NVARCHAR(MAX), @status_code NVARCHAR(60), @row_org BIGINT, @rv BIGINT, @found BIT = 0;
    IF @model_id IS NOT NULL
    BEGIN
        INSERT @old
        SELECT d.organization_id, d.make_id, d.asset_type_id, d.model_name, d.model_number, d.variant, d.hardware_revision,
               d.announcement_date, d.release_date, d.end_of_sale_date, d.end_standard_support_date,
               d.end_security_support_date, d.end_extended_support_date, d.end_of_life_date, d.lifecycle_status,
               s.status_code, CONVERT(BIGINT, d.record_version)
          FROM grac_practice.asset_model d
          JOIN grac_practice.entity_status_master s ON s.entity_status_id = d.current_status_id
         WHERE d.model_id = @model_id;
        SELECT @found = 1, @row_org = organization_id, @status_code = status_code, @rv = rv FROM @old;
        IF @found = 0 OR (@row_org IS NOT NULL AND @row_org <> @organization_id)
            THROW 54807, 'Model not found.', 1;
        IF ISNULL(@row_org, -1) <> ISNULL(@scope_org, -1)
            THROW 54804, 'This model belongs to the shared catalogue; only the platform administrator can change it.', 1;
        IF @expected_record_version IS NOT NULL AND @expected_record_version <> @rv
            THROW 54805, 'This entry was changed by someone else. Reload and try again.', 1;
        IF @status_code = N'APPROVED' AND EXISTS (
            SELECT 1 FROM @old o
             WHERE o.make_id <> @make_id OR o.asset_type_id <> @asset_type_id OR o.model_name <> ISNULL(@model_name, N'')
                OR ISNULL(o.model_number, N'') <> ISNULL(@model_number, N'') OR ISNULL(o.variant, N'') <> ISNULL(@variant, N'')
                OR ISNULL(o.hardware_revision, N'') <> ISNULL(@hardware_revision, N''))
            THROW 54813, 'The model is approved: make, asset type, name, number, variant and hardware revision can no longer change. Withdraw it and create a new model instead.', 1;
    END

    IF @model_name IS NULL THROW 54808, 'The model name is required.', 1;
    IF @lifecycle_status NOT IN (N'PLANNED', N'CURRENT', N'LEGACY', N'APPROACHING_EOS', N'UNSUPPORTED', N'RETIRED')
        THROW 54814, 'Lifecycle status must be Planned, Current, Legacy, Approaching EOS, Unsupported or Retired.', 1;

    -- Make: visible, active (unless unchanged), and a shared model needs a shared make.
    DECLARE @make_org BIGINT, @make_status NVARCHAR(30), @make_found BIT = 0;
    SELECT @make_found = 1, @make_org = organization_id, @make_status = status FROM grac_practice.asset_make WHERE make_id = @make_id;
    IF @make_found = 0 OR (@make_org IS NOT NULL AND @make_org <> @organization_id)
        THROW 54801, 'Make not found.', 1;
    IF @scope_org IS NULL AND @make_org IS NOT NULL
        THROW 54810, 'A shared model must use a make from the shared catalogue.', 1;
    IF @make_status <> N'Active' AND NOT EXISTS (SELECT 1 FROM @old WHERE make_id = @make_id)
        THROW 54810, 'Select an active make.', 1;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.fn_asset_taxonomy_selectable() WHERE NodeKind = N'TYPE' AND NodeId = @asset_type_id)
       AND NOT EXISTS (SELECT 1 FROM @old WHERE asset_type_id = @asset_type_id)
        THROW 54806, 'Select an asset type that is active and in effect.', 1;
    IF @criticality_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM grac_practice.criticality_master WHERE criticality_id = @criticality_id AND is_active = 1)
        THROW 54818, 'Select an active criticality.', 1;

    -- Date sequence (4.8).
    IF @release_date IS NOT NULL AND (
          @announcement_date         > @release_date OR @end_of_sale_date          < @release_date
       OR @end_standard_support_date < @release_date OR @end_security_support_date < @release_date
       OR @end_extended_support_date < @release_date OR @end_of_life_date          < @release_date)
        THROW 54811, 'End-of-sale, end-of-support and end-of-life dates cannot precede the release date, and the announcement cannot follow it.', 1;

    -- Duplicates within the make, among models this scope can see.
    IF EXISTS (SELECT 1 FROM grac_practice.asset_model d
                WHERE d.make_id = @make_id AND d.model_id <> ISNULL(@model_id, -1)
                  AND (d.organization_id IS NULL OR d.organization_id = @organization_id)
                  AND ((@model_number IS NOT NULL AND d.model_number = @model_number)
                       OR (d.model_name = @model_name AND ISNULL(d.variant, N'') = ISNULL(@variant, N'')
                           AND ISNULL(d.hardware_revision, N'') = ISNULL(@hardware_revision, N''))))
        THROW 54809, 'This make already has a model with the same number, or the same name, variant and hardware revision.', 1;

    -- Milestones that change (4.6 / 4.8).
    DECLARE @changes TABLE (milestone_code NVARCHAR(60), before_value NVARCHAR(200), after_value NVARCHAR(200));
    IF @model_id IS NOT NULL
    BEGIN
        INSERT @changes (milestone_code, before_value, after_value)
        SELECT v.code, v.b, v.a
          FROM @old o
         CROSS APPLY (VALUES
            (N'ANNOUNCEMENT_DATE',       CONVERT(NVARCHAR(10), o.announcement_date, 23),         CONVERT(NVARCHAR(10), @announcement_date, 23)),
            (N'RELEASE_DATE',            CONVERT(NVARCHAR(10), o.release_date, 23),              CONVERT(NVARCHAR(10), @release_date, 23)),
            (N'END_OF_SALE_DATE',        CONVERT(NVARCHAR(10), o.end_of_sale_date, 23),          CONVERT(NVARCHAR(10), @end_of_sale_date, 23)),
            (N'END_STANDARD_SUPPORT',    CONVERT(NVARCHAR(10), o.end_standard_support_date, 23), CONVERT(NVARCHAR(10), @end_standard_support_date, 23)),
            (N'END_SECURITY_SUPPORT',    CONVERT(NVARCHAR(10), o.end_security_support_date, 23), CONVERT(NVARCHAR(10), @end_security_support_date, 23)),
            (N'END_EXTENDED_SUPPORT',    CONVERT(NVARCHAR(10), o.end_extended_support_date, 23), CONVERT(NVARCHAR(10), @end_extended_support_date, 23)),
            (N'END_OF_LIFE_DATE',        CONVERT(NVARCHAR(10), o.end_of_life_date, 23),          CONVERT(NVARCHAR(10), @end_of_life_date, 23)),
            (N'LIFECYCLE_STATUS',        o.lifecycle_status,                                     @lifecycle_status)
         ) AS v(code, b, a)
         WHERE ISNULL(v.b, N'') <> ISNULL(v.a, N'');
        IF @change_reason IS NULL AND EXISTS (SELECT 1 FROM @changes WHERE before_value IS NOT NULL)
            THROW 54812, 'A reason is required to change a lifecycle date or status that already had a value.', 1;
    END

    SET @before = (SELECT make_id AS makeId, asset_type_id AS assetTypeId, model_name AS modelName, model_number AS modelNumber,
                          variant, hardware_revision AS hardwareRevision, lifecycle_status AS lifecycleStatus,
                          release_date AS releaseDate, end_of_sale_date AS endOfSaleDate,
                          end_standard_support_date AS endStandardSupportDate, end_security_support_date AS endSecuritySupportDate,
                          end_extended_support_date AS endExtendedSupportDate, end_of_life_date AS endOfLifeDate,
                          source_reference AS sourceReference, criticality_id AS criticalityId
                     FROM grac_practice.asset_model WHERE model_id = @model_id FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    DECLARE @draft_id INT = grac_practice.fn_get_entity_status_id(N'AssetModel', N'DRAFT');
    DECLARE @to_status_id INT, @log_id BIGINT;

    BEGIN TRAN;
    IF @model_id IS NULL
    BEGIN
        DECLARE @make_name NVARCHAR(200);
        SELECT @make_name = make_name FROM grac_practice.asset_make WHERE make_id = @make_id;
        DECLARE @base NVARCHAR(160) = N'MODEL_' + ISNULL(grac_practice.fn_asset_make_code(
                    CONCAT(@make_name, N' ', ISNULL(@model_number, @model_name), N' ', @variant), 80), N'X'),
                @code NVARCHAR(160), @n INT = 1;
        SET @code = @base;
        WHILE EXISTS (SELECT 1 FROM grac_practice.asset_model WHERE model_code = @code)
        BEGIN
            SET @n = @n + 1;
            SET @code = @base + N'_' + CAST(@n AS NVARCHAR(10));
        END
        INSERT grac_practice.asset_model
            (organization_id, make_id, asset_type_id, model_code, model_name, model_number, family_series, variant, sku,
             announcement_date, release_date, end_of_sale_date, end_standard_support_date, end_security_support_date,
             end_extended_support_date, end_of_life_date, architecture, hardware_revision, specifications,
             source_reference, verified_date, verified_by, criticality_id, replacement_lead_time_days, lifecycle_risk,
             controls, lifecycle_status, current_status_id, entered_by)
        VALUES (@scope_org, @make_id, @asset_type_id, @code, @model_name, @model_number,
                NULLIF(LTRIM(RTRIM(@family_series)), N''), @variant, NULLIF(LTRIM(RTRIM(@sku)), N''),
                @announcement_date, @release_date, @end_of_sale_date, @end_standard_support_date, @end_security_support_date,
                @end_extended_support_date, @end_of_life_date, NULLIF(LTRIM(RTRIM(@architecture)), N''), @hardware_revision,
                NULLIF(LTRIM(RTRIM(@specifications)), N''), @source_reference, @verified_date,
                NULLIF(LTRIM(RTRIM(@verified_by)), N''), @criticality_id, @replacement_lead_time_days,
                NULLIF(LTRIM(RTRIM(@lifecycle_risk)), N''), NULLIF(LTRIM(RTRIM(@controls)), N''), @lifecycle_status,
                @draft_id, @actor);
        SET @out_model_id = SCOPE_IDENTITY();

        EXEC grac_practice.sp_pm_state_transition
             @entity_type = N'AssetModel', @entity_id = @out_model_id,
             @from_status_code = NULL, @to_status_code = N'DRAFT',
             @actor_employee_id = @actor_employee_id, @actor_role_code = NULL,
             @reason_code = N'CREATED', @reason_text = NULL,
             @to_status_id = @to_status_id OUTPUT, @transition_log_id = @log_id OUTPUT;
    END
    ELSE
    BEGIN
        UPDATE grac_practice.asset_model
           SET make_id = @make_id, asset_type_id = @asset_type_id, model_name = @model_name, model_number = @model_number,
               family_series = NULLIF(LTRIM(RTRIM(@family_series)), N''), variant = @variant,
               sku = NULLIF(LTRIM(RTRIM(@sku)), N''), announcement_date = @announcement_date, release_date = @release_date,
               end_of_sale_date = @end_of_sale_date, end_standard_support_date = @end_standard_support_date,
               end_security_support_date = @end_security_support_date, end_extended_support_date = @end_extended_support_date,
               end_of_life_date = @end_of_life_date, architecture = NULLIF(LTRIM(RTRIM(@architecture)), N''),
               hardware_revision = @hardware_revision, specifications = NULLIF(LTRIM(RTRIM(@specifications)), N''),
               source_reference = @source_reference, verified_date = @verified_date,
               verified_by = NULLIF(LTRIM(RTRIM(@verified_by)), N''), criticality_id = @criticality_id,
               replacement_lead_time_days = @replacement_lead_time_days,
               lifecycle_risk = NULLIF(LTRIM(RTRIM(@lifecycle_risk)), N''), controls = NULLIF(LTRIM(RTRIM(@controls)), N''),
               lifecycle_status = @lifecycle_status, updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE model_id = @model_id;
        SET @out_model_id = @model_id;

        INSERT grac_practice.technology_lifecycle_event
            (entity_type, entity_id, milestone_code, before_value, after_value, source, reason, impact_count, entered_by)
        SELECT N'MODEL', @model_id, milestone_code, before_value, after_value, @source_reference, @change_reason, NULL, @actor
          FROM @changes;
    END
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-model', @out_model_id, CASE WHEN @model_id IS NULL THEN N'ADD' ELSE N'SAVE' END, @before,
            (SELECT @scope_org AS organizationId, @make_id AS makeId, @asset_type_id AS assetTypeId, @model_name AS modelName,
                    @model_number AS modelNumber, @variant AS variant, @hardware_revision AS hardwareRevision,
                    @lifecycle_status AS lifecycleStatus, @release_date AS releaseDate, @end_of_sale_date AS endOfSaleDate,
                    @end_standard_support_date AS endStandardSupportDate, @end_security_support_date AS endSecuritySupportDate,
                    @end_extended_support_date AS endExtendedSupportDate, @end_of_life_date AS endOfLifeDate,
                    @source_reference AS sourceReference, @criticality_id AS criticalityId, @change_reason AS changeReason
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            N'Active', @actor);
    COMMIT;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_asset_model_transition
    @organization_id         BIGINT,
    @shared                  BIT            = 0,
    @model_id                BIGINT,
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

    DECLARE @from NVARCHAR(60), @rv BIGINT, @row_org BIGINT, @submitted_by NVARCHAR(100), @source NVARCHAR(500),
            @found BIT = 0, @make_status NVARCHAR(30), @type_id INT;
    SELECT @found = 1, @from = s.status_code, @rv = CONVERT(BIGINT, d.record_version), @row_org = d.organization_id,
           @submitted_by = d.submitted_by, @source = d.source_reference, @make_status = m.status, @type_id = d.asset_type_id
      FROM grac_practice.asset_model d
      JOIN grac_practice.entity_status_master s ON s.entity_status_id = d.current_status_id
      JOIN grac_practice.asset_make m ON m.make_id = d.make_id
     WHERE d.model_id = @model_id;
    IF @found = 0 OR (@row_org IS NOT NULL AND @row_org <> @organization_id)
        THROW 54807, 'Model not found.', 1;
    IF ISNULL(@row_org, -1) <> CASE WHEN @shared = 1 THEN -1 ELSE @organization_id END
        THROW 54804, 'This model belongs to the shared catalogue; only the platform administrator can change it.', 1;
    IF @expected_record_version IS NOT NULL AND @expected_record_version <> @rv
        THROW 54805, 'This entry was changed by someone else. Reload and try again.', 1;
    IF @to_status_code IN (N'DRAFT', N'WITHDRAWN') AND @reason_text IS NULL
        THROW 54817, 'A reason is required to return, withdraw or reopen a model.', 1;
    IF @to_status_code IN (N'PENDING_APPROVAL', N'APPROVED')
    BEGIN
        IF @source IS NULL
            THROW 54815, 'Add the source / document reference (vendor page, datasheet or lifecycle notice) before submitting.', 1;
        IF @make_status <> N'Active'
            THROW 54815, 'The make is inactive. Reactivate it or choose another make before submitting.', 1;
        IF NOT EXISTS (SELECT 1 FROM grac_practice.fn_asset_taxonomy_selectable() WHERE NodeKind = N'TYPE' AND NodeId = @type_id)
            THROW 54815, 'The asset type is no longer active or in effect. Choose another asset type before submitting.', 1;
    END
    IF @from = N'PENDING_APPROVAL' AND @to_status_code = N'APPROVED' AND @submitted_by = @actor
        THROW 54816, 'Segregation of duties: the person who submitted this model cannot approve it.', 1;

    DECLARE @reason_code NVARCHAR(60) = CASE @to_status_code
        WHEN N'PENDING_APPROVAL' THEN N'SUBMITTED' WHEN N'APPROVED' THEN N'APPROVED'
        WHEN N'WITHDRAWN' THEN N'WITHDRAWN' WHEN N'DRAFT' THEN CASE WHEN @from = N'WITHDRAWN' THEN N'REOPENED' ELSE N'RETURNED' END
        ELSE NULL END;
    DECLARE @to_status_id INT, @log_id BIGINT;

    BEGIN TRAN;
    EXEC grac_practice.sp_pm_state_transition
         @entity_type = N'AssetModel', @entity_id = @model_id,
         @from_status_code = @from, @to_status_code = @to_status_code,
         @actor_employee_id = @actor_employee_id, @actor_role_code = NULL,
         @reason_code = @reason_code, @reason_text = @reason_text,
         @to_status_id = @to_status_id OUTPUT, @transition_log_id = @log_id OUTPUT;
    UPDATE grac_practice.asset_model
       SET current_status_id = @to_status_id,
           submitted_by = CASE WHEN @to_status_code = N'PENDING_APPROVAL' THEN @actor WHEN @to_status_code = N'DRAFT' THEN NULL ELSE submitted_by END,
           submitted_dt = CASE WHEN @to_status_code = N'PENDING_APPROVAL' THEN SYSUTCDATETIME() WHEN @to_status_code = N'DRAFT' THEN NULL ELSE submitted_dt END,
           approved_by  = CASE WHEN @to_status_code = N'APPROVED' THEN @actor WHEN @to_status_code = N'DRAFT' THEN NULL ELSE approved_by END,
           approved_dt  = CASE WHEN @to_status_code = N'APPROVED' THEN SYSUTCDATETIME() WHEN @to_status_code = N'DRAFT' THEN NULL ELSE approved_dt END,
           updated_by = @actor, updated_dt = SYSUTCDATETIME()
     WHERE model_id = @model_id;
    COMMIT;

    SELECT @model_id AS ModelId, @to_status_code AS StatusCode;
END
GO
PRINT '425: technology catalogue procedures created.';
GO

-- =====================================================================
-- 5. Menu: Asset & Contract -> Technology Catalogue (also carried in 274)
-- =====================================================================
MERGE grac_practice.menu_master AS t
USING (VALUES
    (N'asset-tech-catalog', N'Technology Catalogue', N'Practice/Index/asset-tech-catalog', 356, N'microchip', N'Asset & Contract')
) AS s(menu_key, menu_name, menu_url, display_order, icon_class, module_type)
ON t.menu_key = s.menu_key
WHEN MATCHED AND (ISNULL(t.menu_name, N'') <> s.menu_name OR ISNULL(t.menu_url, N'') <> s.menu_url
               OR t.display_order <> s.display_order OR ISNULL(t.icon_class, N'') <> s.icon_class
               OR ISNULL(t.module_type, N'') <> s.module_type OR t.status <> N'Active') THEN UPDATE SET
    menu_name = s.menu_name, menu_url = s.menu_url, display_order = s.display_order, icon_class = s.icon_class,
    module_type = s.module_type, status = N'Active', updated_by = N'seed-425', updated_dt = SYSUTCDATETIME()
WHEN NOT MATCHED BY TARGET THEN
    INSERT (menu_key, menu_name, menu_url, display_order, icon_class, module_type, status, entered_by)
    VALUES (s.menu_key, s.menu_name, s.menu_url, s.display_order, s.icon_class, s.module_type, N'Active', N'seed-425');
PRINT CONCAT('425: menu row upserted: ', @@ROWCOUNT);
GO

UPDATE c
   SET parent_menu_id = p.menu_id, updated_by = N'seed-425', updated_dt = SYSUTCDATETIME()
  FROM grac_practice.menu_master c
  JOIN grac_practice.menu_master p ON p.menu_key = N'nav-asset-contract'
 WHERE c.menu_key = N'asset-tech-catalog' AND ISNULL(c.parent_menu_id, -1) <> p.menu_id;
GO

DECLARE @active_rs INT = (
    SELECT TOP 1 record_status_id FROM grac_practice.record_status_master
     WHERE status_code = N'Active' OR status_name = N'Active' ORDER BY record_status_id);
IF @active_rs IS NULL SET @active_rs = 1;
INSERT grac_practice.organization_role_menu_permission
    (role_id, menu_id, can_view, can_add, can_edit, can_delete, can_approve, status, record_status_id, entered_by, entered_dt)
SELECT r.role_id, m.menu_id, 1, 1, 1, 0, 1, N'Active', @active_rs, N'seed-425', SYSUTCDATETIME()
  FROM grac_practice.organization_role r
  JOIN grac_practice.menu_master m ON m.menu_key = N'asset-tech-catalog'
 WHERE r.role_name = N'Admin' AND r.status = N'Active'
   AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_role_menu_permission e
                    WHERE e.role_id = r.role_id AND e.menu_id = m.menu_id);
PRINT CONCAT('425: Admin grants inserted: ', @@ROWCOUNT);
GO

-- =====================================================================
-- Verification
-- =====================================================================
SELECT '425-a tables present' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.asset_make','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.asset_make_asset_type','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.asset_model','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.technology_lifecycle_event','U') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '425-b AssetModel lifecycle (4 statuses, 7 rules)',
       CASE WHEN (SELECT COUNT(*) FROM grac_practice.entity_status_master WHERE entity_type = N'AssetModel') = 4
             AND (SELECT COUNT(*) FROM grac_practice.entity_state_transition_rule WHERE entity_type = N'AssetModel') = 7
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '425-c procedures present',
       CASE WHEN (SELECT COUNT(*) FROM sys.procedures WHERE SCHEMA_NAME(schema_id) = 'grac_practice'
                   AND name IN ('sp_asset_tech_catalog_list', 'sp_asset_model_get', 'sp_asset_make_save',
                                'sp_asset_model_save', 'sp_asset_model_transition')) = 5 THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '425-d menu row Active under Asset & Contract',
       CASE WHEN EXISTS (SELECT 1 FROM grac_practice.menu_master c
                           JOIN grac_practice.menu_master p ON p.menu_id = c.parent_menu_id AND p.menu_key = N'nav-asset-contract'
                          WHERE c.menu_key = N'asset-tech-catalog' AND c.status = N'Active') THEN 'PASS' ELSE 'FAIL' END;
GO

-- =====================================================================
-- UAT (after deploying the API + Web build; re-login for the menu grant)
--   1. Asset & Contract -> Technology Catalogue -> Makes -> Add Make:
--      name, legal name, aliases "HP; Hewlett-Packard", support portal,
--      supported asset types. Save. Add another make named "HP" --
--      refused (54803, matches an alias).
--   2. Models -> Add Model for that make and an asset type; set release
--      date 2024-01-01 and end of standard support 2023-12-31 -- refused
--      (54811). Fix and save (Draft).
--   3. Submit without a source reference -- refused (54815). Add one,
--      submit; approve as the same user -- refused (54816); approve as
--      another admin -- Approved.
--   4. Edit the approved model: change its name -- refused (54813);
--      change end of life without a reason -- refused (54812); with a
--      reason -- saved, and History shows the milestone with before /
--      after and reason.
--   5. Withdraw (reason required), then Reopen (reason) -> Draft.
--   6. As an organization Admin, an organization make / model is saved
--      for this organization only; shared rows are read-only unless the
--      user is the platform administrator, who can tick "Shared
--      catalogue" when adding.
-- =====================================================================
