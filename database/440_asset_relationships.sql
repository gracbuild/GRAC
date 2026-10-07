-- =====================================================================
-- 440  CMDB relationships: relationship types, effective-dated asset /
--      configuration-item relationships with governance, impact analysis
--      and the retirement gate (Asset & Contract Management, Phase 7
--      increment 1)
--
-- REQUEST
-- -------
--   BRD v1.7 5.4 "Asset Relationships and Dependency Mapping": effective-
--   dated, directional, auditable relationships among assets, applications,
--   processes, suppliers and locations (business services follow in 7.2);
--   the twelve relationship types (Parent / Child, Depends On, Hosted On,
--   Runs On, Connected To, Protects, Stores Data For, Backed Up By,
--   Monitored By, Supports Service, Located In, Replaces); 5.4.1 record
--   fields (ID, source / target CI, type with direction and inverse label,
--   critical dependency and criticality, impact weight, status Proposed /
--   Active / Disputed / Inactive / Retired, effective from / to, source,
--   confidence, owner / verifier, evidence / change reference, audit);
--   5.4.2 governance (type masters define permitted source / target
--   classes, direction, cardinality and loop rules; circular dependencies
--   blocked where configured and permitted loops flagged; changes to
--   critical relationships need impact preview and approval; impact
--   analysis traverses a configurable upstream / downstream depth without
--   double counting a CI; retiring an asset is blocked until its active
--   critical dependencies are reassigned, accepted as exceptions or closed;
--   history survives retirement); 5.4.4 acceptance criteria. Plan:
--   docs/asset-contract-management.md (Phase 7.1, D79-D87).
--
-- WHAT THIS DOES
-- --------------
--   1. asset_relationship_type (global): the twelve BRD types with label and
--      inverse label, permitted source / target kinds, cardinality, loop
--      rule and the dependent side used by impact analysis. Supports
--      Service is inactive until business services exist (7.2).
--   2. asset_relationship (per organization) and asset_relationship_history
--      (one row per version / action -- topology history).
--   3. CI catalogue (fn_asset_ci_catalog): assets, applications, processes,
--      vendors and locations of the organization as relationship endpoints.
--   4. Governance: type, kinds, endpoints, duplicates, cardinality and
--      loops checked on proposal and on approval; proposals approved by a
--      holder of APPROVE (another person for a critical relationship);
--      changes to an active critical relationship and its retirement wait
--      for approval (pending change); dispute / confirm; retire; acceptance
--      of a critical dependency for retirement; effective-to expiry.
--   5. Impact analysis (sp_asset_ci_impact): downstream (what is affected
--      when the CI fails) or upstream (what the CI relies on), depth 1-10,
--      critical-only, each CI once at its nearest level; preview of a
--      proposed relationship.
--   6. Lifecycle gate: sp_asset_lifecycle_transition (435 body) re-issued --
--      moving an asset into sanitization, disposal approval, Disposed or
--      Archived is blocked while active critical relationships depend on it
--      and were not accepted for retirement.
--   7. Asset Relationships screen (menu row, readers / writers).
--
-- NOT DONE HERE: business services and the Supports Service type (7.2);
--   discovered / imported / inferred relationships and their confidence
--   (7.3); service, risk, change and continuity reviews raised by a
--   relationship change (later phases); organization-defined relationship
--   types; the retirement gate on the approval of an already requested
--   lifecycle change (checked when it is requested).
--
-- ERROR NUMBERS: 54701-54729 (54700 is used by 047)
--   54701 organization not found           54702 unknown / inactive type
--   54703 kind not permitted for the type  54704 endpoint not found / not usable
--   54705 source and target are the same   54706 relationship already exists
--   54707 cardinality                      54708 circular dependency blocked
--   54709 relationship not found           54710 changed by someone else
--   54711 not editable in its status       54712 a change is already pending
--   54713 reason / note required           54714 effective dates
--   54715 action not valid now             54716 segregation of duties
--   54717 criticality / weight / confidence 54718 owner / verifier
--   54719 retirement blocked (lifecycle)   54720 CI kind / direction not valid
--
-- ALSO EDITED: API (AssetConfig service / controller / models), Web proxy,
--   PracticeScreen + Manage.cshtml + appsettings, asset-relationships.cshtml
--   / .js (new), 274 (menu), docs.
-- DEPENDS ON: 428, 429, 435.
-- Rollback: 440_asset_relationships_rollback.sql
-- Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.sp_asset_lifecycle_transition','P') IS NULL
   OR OBJECT_ID('grac_practice.fn_asset_coverage_gaps') IS NULL
   OR COL_LENGTH('grac_practice.organization_dependency_asset','current_status_id') IS NULL
   OR COL_LENGTH('grac_practice.organization_dependency_asset','template_id') IS NULL
   OR OBJECT_ID('grac_practice.asset_lifecycle_transition_gate','U') IS NULL
   OR OBJECT_ID('grac_practice.asset_lifecycle_change','U') IS NULL
   OR OBJECT_ID('grac_practice.asset_legacy_status_map','U') IS NULL
   OR OBJECT_ID('grac_practice.sp_asset_lifecycle_apply','P') IS NULL
BEGIN
    RAISERROR('ABORT (440): run 428, 429 and 435 first.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. Relationship types (global, BRD 5.4)
-- =====================================================================
IF OBJECT_ID('grac_practice.asset_relationship_type','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_relationship_type (
        type_code       NVARCHAR(30)  NOT NULL CONSTRAINT pk_pm_asset_rel_type PRIMARY KEY,
        type_name       NVARCHAR(100) NOT NULL,     -- forward label: source <type_name> target
        inverse_label   NVARCHAR(100) NOT NULL,     -- target <inverse_label> source
        brd_pair        NVARCHAR(100) NOT NULL,
        description     NVARCHAR(400) NOT NULL,
        source_kinds    NVARCHAR(200) NOT NULL,     -- comma list of ASSET, APPLICATION, PROCESS, VENDOR, LOCATION, SERVICE
        target_kinds    NVARCHAR(200) NOT NULL,
        cardinality     NVARCHAR(12)  NOT NULL
            CONSTRAINT ck_pm_asset_rel_type_card CHECK (cardinality IN (N'MANY', N'ONE_TARGET', N'ONE_SOURCE', N'ONE_TO_ONE')),
        loop_rule       NVARCHAR(6)   NOT NULL
            CONSTRAINT ck_pm_asset_rel_type_loop CHECK (loop_rule IN (N'BLOCK', N'FLAG', N'ALLOW')),
        dependent_side  NVARCHAR(6)   NOT NULL      -- the side that is impacted when the other fails
            CONSTRAINT ck_pm_asset_rel_type_dep CHECK (dependent_side IN (N'SOURCE', N'TARGET', N'NONE')),
        is_active       BIT           NOT NULL,
        inactive_reason NVARCHAR(200) NULL,
        display_order   INT           NOT NULL,
        entered_by      NVARCHAR(100) NOT NULL CONSTRAINT df_pm_asset_rel_type_eby DEFAULT N'system',
        entered_dt      DATETIME2     NOT NULL CONSTRAINT df_pm_asset_rel_type_edt DEFAULT SYSUTCDATETIME()
    );
    PRINT '440: asset_relationship_type created.';
END
GO

MERGE grac_practice.asset_relationship_type AS t
USING (VALUES
    (N'CONTAINS', N'Contains', N'Is part of', N'Parent / Child', N'Chassis contains module; an enclosure contains a component.',
     N'ASSET', N'ASSET', N'ONE_SOURCE', N'BLOCK', N'TARGET', 1, NULL, 10),
    (N'DEPENDS_ON', N'Depends on', N'Is required by', N'Depends On / Required By', N'Application depends on database.',
     N'ASSET,APPLICATION,PROCESS', N'ASSET,APPLICATION,PROCESS,VENDOR', N'MANY', N'BLOCK', N'SOURCE', 1, NULL, 20),
    (N'HOSTED_ON', N'Is hosted on', N'Hosts', N'Hosted On / Hosts', N'Virtual machine is hosted on a hypervisor.',
     N'ASSET,APPLICATION', N'ASSET', N'ONE_TARGET', N'BLOCK', N'SOURCE', 1, NULL, 30),
    (N'RUNS_ON', N'Runs on', N'Runs', N'Runs On / Runs', N'Application runs on a server.',
     N'APPLICATION', N'ASSET', N'MANY', N'BLOCK', N'SOURCE', 1, NULL, 40),
    (N'CONNECTED_TO', N'Is connected to', N'Is connected to', N'Connected To', N'Device or network connection.',
     N'ASSET', N'ASSET', N'MANY', N'ALLOW', N'NONE', 1, NULL, 50),
    (N'PROTECTS', N'Protects', N'Is protected by', N'Protects / Protected By', N'Firewall protects an application or network.',
     N'ASSET,APPLICATION', N'ASSET,APPLICATION', N'MANY', N'FLAG', N'TARGET', 1, NULL, 60),
    (N'STORES_DATA_FOR', N'Stores data for', N'Has data stored in', N'Stores Data For', N'Database or storage supports an application or process.',
     N'ASSET,APPLICATION', N'APPLICATION,PROCESS', N'MANY', N'BLOCK', N'TARGET', 1, NULL, 70),
    (N'BACKED_UP_BY', N'Is backed up by', N'Backs up', N'Backed Up By', N'Asset is protected by a backup system or provider.',
     N'ASSET,APPLICATION', N'ASSET,APPLICATION,VENDOR', N'MANY', N'FLAG', N'SOURCE', 1, NULL, 80),
    (N'MONITORED_BY', N'Is monitored by', N'Monitors', N'Monitored By', N'Asset sends telemetry to a monitoring tool or provider.',
     N'ASSET,APPLICATION', N'ASSET,APPLICATION,VENDOR', N'MANY', N'ALLOW', N'NONE', 1, NULL, 90),
    (N'SUPPORTS_SERVICE', N'Supports service', N'Is supported by', N'Supports Service / Supported By', N'Asset contributes to a business service.',
     N'ASSET,APPLICATION,PROCESS,VENDOR', N'SERVICE', N'MANY', N'BLOCK', N'TARGET', 0, N'Available with business services (Phase 7.2).', 100),
    (N'LOCATED_IN', N'Is located in', N'Contains', N'Located In / Contains', N'Asset placed within a rack, cabinet or enclosure asset, or a site.',
     N'ASSET', N'ASSET,LOCATION', N'ONE_TARGET', N'BLOCK', N'SOURCE', 1, NULL, 110),
    (N'REPLACES', N'Replaces', N'Is replaced by', N'Replaces / Replaced By', N'Successor / predecessor lifecycle link.',
     N'ASSET', N'ASSET', N'ONE_TO_ONE', N'BLOCK', N'NONE', 1, NULL, 120)
) AS s(type_code, type_name, inverse_label, brd_pair, description, source_kinds, target_kinds, cardinality, loop_rule,
       dependent_side, is_active, inactive_reason, display_order)
ON t.type_code = s.type_code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (type_code, type_name, inverse_label, brd_pair, description, source_kinds, target_kinds, cardinality, loop_rule,
            dependent_side, is_active, inactive_reason, display_order, entered_by)
    VALUES (s.type_code, s.type_name, s.inverse_label, s.brd_pair, s.description, s.source_kinds, s.target_kinds, s.cardinality,
            s.loop_rule, s.dependent_side, s.is_active, s.inactive_reason, s.display_order, N'seed-440');
PRINT CONCAT('440: relationship types inserted: ', @@ROWCOUNT);
GO

-- =====================================================================
-- 2. Relationships and their history (5.4.1)
-- =====================================================================
IF OBJECT_ID('grac_practice.asset_relationship','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_relationship (
        relationship_id          BIGINT         IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_asset_rel PRIMARY KEY,
        organization_id          BIGINT         NOT NULL,
        relationship_type_code   NVARCHAR(30)   NOT NULL
            CONSTRAINT fk_pm_asset_rel_type REFERENCES grac_practice.asset_relationship_type(type_code),
        source_kind              NVARCHAR(12)   NOT NULL
            CONSTRAINT ck_pm_asset_rel_skind CHECK (source_kind IN (N'ASSET', N'APPLICATION', N'PROCESS', N'VENDOR', N'LOCATION', N'SERVICE')),
        source_id                BIGINT         NOT NULL,
        target_kind              NVARCHAR(12)   NOT NULL
            CONSTRAINT ck_pm_asset_rel_tkind CHECK (target_kind IN (N'ASSET', N'APPLICATION', N'PROCESS', N'VENDOR', N'LOCATION', N'SERVICE')),
        target_id                BIGINT         NOT NULL,
        is_critical              BIT            NOT NULL CONSTRAINT df_pm_asset_rel_crit DEFAULT 0,
        dependency_criticality   NVARCHAR(10)   NULL
            CONSTRAINT ck_pm_asset_rel_depcrit CHECK (dependency_criticality IS NULL
                OR dependency_criticality IN (N'CRITICAL', N'HIGH', N'MEDIUM', N'LOW')),
        impact_weight            DECIMAL(5, 2)  NULL,
        status                   NVARCHAR(10)   NOT NULL
            CONSTRAINT ck_pm_asset_rel_status CHECK (status IN (N'PROPOSED', N'ACTIVE', N'DISPUTED', N'INACTIVE', N'RETIRED')),
        effective_from           DATE           NOT NULL,
        effective_to             DATE           NULL,
        source_code              NVARCHAR(10)   NOT NULL CONSTRAINT df_pm_asset_rel_src DEFAULT N'MANUAL'
            CONSTRAINT ck_pm_asset_rel_src CHECK (source_code IN (N'MANUAL', N'DISCOVERY', N'IMPORT', N'API', N'INFERENCE')),
        confidence_pct           INT            NULL,
        verification_status      NVARCHAR(10)   NOT NULL CONSTRAINT df_pm_asset_rel_ver DEFAULT N'UNVERIFIED'
            CONSTRAINT ck_pm_asset_rel_ver CHECK (verification_status IN (N'VERIFIED', N'UNVERIFIED')),
        owner_employee_id        BIGINT         NULL
            CONSTRAINT fk_pm_asset_rel_owner REFERENCES grac_practice.organization_employee(employee_id),
        verifier_employee_id     BIGINT         NULL
            CONSTRAINT fk_pm_asset_rel_verifier REFERENCES grac_practice.organization_employee(employee_id),
        evidence_reference       NVARCHAR(400)  NULL,
        change_reference         NVARCHAR(200)  NULL,
        reason                   NVARCHAR(1000) NULL,
        in_loop                  BIT            NOT NULL CONSTRAINT df_pm_asset_rel_loop DEFAULT 0,
        version_no               INT            NOT NULL CONSTRAINT df_pm_asset_rel_vno DEFAULT 1,
        proposed_by              NVARCHAR(100)  NOT NULL,
        proposed_by_employee_id  BIGINT         NULL,
        proposed_dt              DATETIME2      NOT NULL CONSTRAINT df_pm_asset_rel_pdt DEFAULT SYSUTCDATETIME(),
        approved_by              NVARCHAR(100)  NULL,
        approved_by_employee_id  BIGINT         NULL,
        approved_dt              DATETIME2      NULL,
        pending_action           NVARCHAR(10)   NULL
            CONSTRAINT ck_pm_asset_rel_pend CHECK (pending_action IS NULL OR pending_action IN (N'UPDATE', N'RETIRE')),
        pending_json             NVARCHAR(MAX)  NULL,
        pending_reason           NVARCHAR(1000) NULL,
        pending_by               NVARCHAR(100)  NULL,
        pending_by_employee_id   BIGINT         NULL,
        pending_dt               DATETIME2      NULL,
        retirement_accepted      BIT            NOT NULL CONSTRAINT df_pm_asset_rel_racc DEFAULT 0,
        retirement_note          NVARCHAR(1000) NULL,
        retirement_accepted_by   NVARCHAR(100)  NULL,
        retirement_accepted_dt   DATETIME2      NULL,
        status_note              NVARCHAR(1000) NULL,      -- dispute / rejection / retirement note
        entered_by               NVARCHAR(100)  NOT NULL CONSTRAINT df_pm_asset_rel_eby DEFAULT N'system',
        entered_dt               DATETIME2      NOT NULL CONSTRAINT df_pm_asset_rel_edt DEFAULT SYSUTCDATETIME(),
        updated_by               NVARCHAR(100)  NULL,
        updated_dt               DATETIME2      NULL,
        record_version           ROWVERSION     NOT NULL,
        CONSTRAINT ck_pm_asset_rel_dates CHECK (effective_to IS NULL OR effective_to >= effective_from),
        CONSTRAINT ck_pm_asset_rel_weight CHECK (impact_weight IS NULL OR impact_weight BETWEEN 0 AND 100),
        CONSTRAINT ck_pm_asset_rel_conf CHECK (confidence_pct IS NULL OR confidence_pct BETWEEN 0 AND 100)
    );
    -- One current relationship of a type between the same two CIs.
    CREATE UNIQUE INDEX ux_pm_asset_rel_current ON grac_practice.asset_relationship
        (organization_id, relationship_type_code, source_kind, source_id, target_kind, target_id)
        WHERE status IN (N'PROPOSED', N'ACTIVE', N'DISPUTED');
    CREATE INDEX ix_pm_asset_rel_org ON grac_practice.asset_relationship(organization_id, status);
    CREATE INDEX ix_pm_asset_rel_src ON grac_practice.asset_relationship(source_kind, source_id);
    CREATE INDEX ix_pm_asset_rel_tgt ON grac_practice.asset_relationship(target_kind, target_id);
    PRINT '440: asset_relationship created.';
END
GO

IF OBJECT_ID('grac_practice.asset_relationship_history','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_relationship_history (
        history_id        BIGINT         IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_asset_rel_hist PRIMARY KEY,
        relationship_id   BIGINT         NOT NULL
            CONSTRAINT fk_pm_asset_rel_hist_rel REFERENCES grac_practice.asset_relationship(relationship_id),
        organization_id   BIGINT         NOT NULL,
        version_no        INT            NOT NULL,
        action_code       NVARCHAR(20)   NOT NULL,
        status            NVARCHAR(10)   NOT NULL,
        snapshot_json     NVARCHAR(MAX)  NOT NULL,
        note              NVARCHAR(1000) NULL,
        actor             NVARCHAR(100)  NOT NULL,
        actor_employee_id BIGINT         NULL,
        entered_dt        DATETIME2      NOT NULL CONSTRAINT df_pm_asset_rel_hist_edt DEFAULT SYSUTCDATETIME()
    );
    CREATE INDEX ix_pm_asset_rel_hist_rel ON grac_practice.asset_relationship_history(relationship_id, history_id);
    PRINT '440: asset_relationship_history created.';
END
GO

-- =====================================================================
-- 3. Helpers
-- =====================================================================
-- Relationship endpoints of an organization (D80): assets (usable unless
-- Disposed / Archived), applications, processes, vendors and locations
-- (usable while Active).
CREATE OR ALTER FUNCTION grac_practice.fn_asset_ci_catalog (@organization_id BIGINT)
RETURNS TABLE
AS
RETURN
    SELECT N'ASSET' AS CiKind, a.asset_id AS CiId, CAST(a.asset_name AS NVARCHAR(400)) AS CiName,
           CAST(ISNULL(ty.asset_type_name, N'Asset') AS NVARCHAR(200)) AS CiClass,
           CAST(ISNULL(s.status_name, N'Active') AS NVARCHAR(120)) AS CiStatus,
           CAST(CASE WHEN ISNULL(s.status_code, N'ACTIVE') IN (N'DISPOSED', N'ARCHIVED') THEN 0 ELSE 1 END AS BIT) AS IsUsable,
           a.owner_id AS OwnerEmployeeId
      FROM grac_practice.organization_dependency_asset a
      LEFT JOIN grac_practice.entity_status_master s ON s.entity_status_id = a.current_status_id
      LEFT JOIN grac_practice.dependency_asset_type_master ty ON ty.asset_type_id = a.asset_type_id
     WHERE a.organization_id = @organization_id
    UNION ALL
    SELECT N'APPLICATION', p.application_id, CAST(p.application_name AS NVARCHAR(400)), CAST(N'Application' AS NVARCHAR(200)),
           CAST(p.status AS NVARCHAR(120)), CAST(CASE WHEN p.status = N'Active' THEN 1 ELSE 0 END AS BIT), p.business_owner_id
      FROM grac_practice.organization_dependency_application p
     WHERE p.organization_id = @organization_id
    UNION ALL
    SELECT N'PROCESS', p.process_id, CAST(p.process_name AS NVARCHAR(400)), CAST(N'Process' AS NVARCHAR(200)),
           CAST(p.status AS NVARCHAR(120)), CAST(CASE WHEN p.status = N'Active' THEN 1 ELSE 0 END AS BIT), p.process_owner_id
      FROM grac_practice.organization_dependency_process p
     WHERE p.organization_id = @organization_id
    UNION ALL
    SELECT N'VENDOR', v.vendor_id, CAST(v.vendor_name AS NVARCHAR(400)), CAST(N'Vendor' AS NVARCHAR(200)),
           CAST(v.status AS NVARCHAR(120)), CAST(CASE WHEN v.status = N'Active' THEN 1 ELSE 0 END AS BIT), v.relationship_owner_id
      FROM grac_practice.organization_dependency_vendor v
     WHERE v.organization_id = @organization_id
    UNION ALL
    SELECT N'LOCATION', l.location_id, CAST(l.location_name AS NVARCHAR(400)), CAST(N'Location' AS NVARCHAR(200)),
           CAST(l.status AS NVARCHAR(120)), CAST(CASE WHEN l.status = N'Active' THEN 1 ELSE 0 END AS BIT), l.location_head_id
      FROM grac_practice.organization_location l
     WHERE l.organization_id = @organization_id;
GO

-- Dependency edges (dependent -> provider) of the relationships in the
-- given statuses; types whose dependent side is NONE carry no impact.
CREATE OR ALTER FUNCTION grac_practice.fn_asset_relationship_edges (@organization_id BIGINT, @current_only BIT)
RETURNS TABLE
AS
RETURN
    SELECT r.relationship_id AS RelationshipId, r.relationship_type_code AS TypeCode, r.is_critical AS IsCritical, r.status AS Status,
           CASE WHEN t.dependent_side = N'SOURCE' THEN r.source_kind ELSE r.target_kind END AS DependentKind,
           CASE WHEN t.dependent_side = N'SOURCE' THEN r.source_id ELSE r.target_id END AS DependentId,
           CASE WHEN t.dependent_side = N'SOURCE' THEN r.target_kind ELSE r.source_kind END AS ProviderKind,
           CASE WHEN t.dependent_side = N'SOURCE' THEN r.target_id ELSE r.source_id END AS ProviderId,
           r.retirement_accepted AS RetirementAccepted
      FROM grac_practice.asset_relationship r
      JOIN grac_practice.asset_relationship_type t ON t.type_code = r.relationship_type_code
     WHERE r.organization_id = @organization_id AND t.dependent_side <> N'NONE'
       AND ((@current_only = 1 AND r.status = N'ACTIVE'
             AND r.effective_from <= CAST(SYSUTCDATETIME() AS DATE)
             AND (r.effective_to IS NULL OR r.effective_to >= CAST(SYSUTCDATETIME() AS DATE)))
            OR (@current_only = 0 AND r.status IN (N'PROPOSED', N'ACTIVE', N'DISPUTED')));
GO

-- Active critical relationships that rely on a CI and were not accepted
-- for its retirement (5.4.2 retirement gate, D86).
CREATE OR ALTER FUNCTION grac_practice.fn_asset_relationship_blockers (@organization_id BIGINT, @ci_kind NVARCHAR(12), @ci_id BIGINT)
RETURNS TABLE
AS
RETURN
    SELECT e.RelationshipId, e.TypeCode, e.DependentKind, e.DependentId
      FROM grac_practice.fn_asset_relationship_edges(@organization_id, 1) e
     WHERE e.ProviderKind = @ci_kind AND e.ProviderId = @ci_id AND e.IsCritical = 1 AND e.RetirementAccepted = 0;
GO

-- Validates a relationship (new or being approved): type, kinds,
-- endpoints, duplicates, cardinality, loops (D81-D83). @out_loop = 1 when
-- the relationship closes a loop its type permits (flagged).
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_relationship_check
    @organization_id BIGINT,
    @relationship_id BIGINT        = NULL,     -- excluded from the duplicate / cardinality / loop checks
    @type_code       NVARCHAR(30),
    @source_kind     NVARCHAR(12),
    @source_id       BIGINT,
    @target_kind     NVARCHAR(12),
    @target_id       BIGINT,
    @out_loop        BIT           = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @out_loop = 0;
    DECLARE @active BIT, @type_name NVARCHAR(100), @src_kinds NVARCHAR(200), @tgt_kinds NVARCHAR(200), @card NVARCHAR(12),
            @loop NVARCHAR(6), @side NVARCHAR(6), @msg NVARCHAR(1000), @self BIGINT = ISNULL(@relationship_id, -1);
    SELECT @active = is_active, @type_name = type_name, @src_kinds = source_kinds, @tgt_kinds = target_kinds, @card = cardinality,
           @loop = loop_rule, @side = dependent_side
      FROM grac_practice.asset_relationship_type WHERE type_code = @type_code;
    IF ISNULL(@active, 0) = 0 THROW 54702, 'Select an active relationship type.', 1;
    IF CHARINDEX(N',' + ISNULL(@source_kind, N'') + N',', N',' + @src_kinds + N',') = 0
       OR CHARINDEX(N',' + ISNULL(@target_kind, N'') + N',', N',' + @tgt_kinds + N',') = 0
    BEGIN
        SET @msg = CONCAT(N'"', @type_name, N'" links a source of kind ', REPLACE(@src_kinds, N',', N' / '),
                          N' to a target of kind ', REPLACE(@tgt_kinds, N',', N' / '), N'.');
        THROW 54703, @msg, 1;
    END
    IF @source_kind = @target_kind AND @source_id = @target_id
        THROW 54705, 'The source and the target must be different.', 1;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.fn_asset_ci_catalog(@organization_id) c
                    WHERE c.CiKind = @source_kind AND c.CiId = @source_id AND c.IsUsable = 1)
        THROW 54704, 'The source was not found in this organization or is no longer in use.', 1;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.fn_asset_ci_catalog(@organization_id) c
                    WHERE c.CiKind = @target_kind AND c.CiId = @target_id AND c.IsUsable = 1)
        THROW 54704, 'The target was not found in this organization or is no longer in use.', 1;
    IF EXISTS (SELECT 1 FROM grac_practice.asset_relationship
                WHERE organization_id = @organization_id AND relationship_type_code = @type_code
                  AND source_kind = @source_kind AND source_id = @source_id AND target_kind = @target_kind AND target_id = @target_id
                  AND status IN (N'PROPOSED', N'ACTIVE', N'DISPUTED') AND relationship_id <> @self)
        THROW 54706, 'This relationship already exists (proposed, active or disputed).', 1;
    IF @card IN (N'ONE_TARGET', N'ONE_TO_ONE')
       AND EXISTS (SELECT 1 FROM grac_practice.asset_relationship
                    WHERE organization_id = @organization_id AND relationship_type_code = @type_code
                      AND source_kind = @source_kind AND source_id = @source_id
                      AND status IN (N'PROPOSED', N'ACTIVE', N'DISPUTED') AND relationship_id <> @self)
    BEGIN
        SET @msg = CONCAT(N'The source already has a "', @type_name, N'" relationship; retire it first (one target only).');
        THROW 54707, @msg, 1;
    END
    IF @card IN (N'ONE_SOURCE', N'ONE_TO_ONE')
       AND EXISTS (SELECT 1 FROM grac_practice.asset_relationship
                    WHERE organization_id = @organization_id AND relationship_type_code = @type_code
                      AND target_kind = @target_kind AND target_id = @target_id
                      AND status IN (N'PROPOSED', N'ACTIVE', N'DISPUTED') AND relationship_id <> @self)
    BEGIN
        SET @msg = CONCAT(N'The target already has a "', @type_name, N'" relationship; retire it first (one source only).');
        THROW 54707, @msg, 1;
    END

    IF @loop = N'ALLOW' RETURN;
    -- Loop: does the provider (or, for a type without impact, the target)
    -- already reach the other end? Breadth-first walk with a visited set.
    DECLARE @from_kind NVARCHAR(12), @from_id BIGINT, @to_kind NVARCHAR(12), @to_id BIGINT;
    CREATE TABLE #edge (dk NVARCHAR(12) NOT NULL, di BIGINT NOT NULL, pk NVARCHAR(12) NOT NULL, pi BIGINT NOT NULL);
    IF @side = N'NONE'
    BEGIN
        INSERT #edge (dk, di, pk, pi)
        SELECT source_kind, source_id, target_kind, target_id FROM grac_practice.asset_relationship
         WHERE organization_id = @organization_id AND relationship_type_code = @type_code
           AND status IN (N'PROPOSED', N'ACTIVE', N'DISPUTED') AND relationship_id <> @self;
        SELECT @from_kind = @target_kind, @from_id = @target_id, @to_kind = @source_kind, @to_id = @source_id;
    END
    ELSE
    BEGIN
        INSERT #edge (dk, di, pk, pi)
        SELECT DependentKind, DependentId, ProviderKind, ProviderId FROM grac_practice.fn_asset_relationship_edges(@organization_id, 0)
         WHERE RelationshipId <> @self;
        -- new edge: dependent -> provider; a loop exists when the provider already depends on the dependent.
        SELECT @from_kind = CASE WHEN @side = N'SOURCE' THEN @target_kind ELSE @source_kind END,
               @from_id   = CASE WHEN @side = N'SOURCE' THEN @target_id ELSE @source_id END,
               @to_kind   = CASE WHEN @side = N'SOURCE' THEN @source_kind ELSE @target_kind END,
               @to_id     = CASE WHEN @side = N'SOURCE' THEN @source_id ELSE @target_id END;
    END
    CREATE TABLE #seen (k NVARCHAR(12) NOT NULL, i BIGINT NOT NULL, lvl INT NOT NULL, PRIMARY KEY (k, i));
    INSERT #seen (k, i, lvl) VALUES (@from_kind, @from_id, 0);
    DECLARE @lvl INT = 0, @hit BIT = 0;
    WHILE @lvl < 100 AND @hit = 0
    BEGIN
        INSERT #seen (k, i, lvl)
        SELECT DISTINCT e.pk, e.pi, @lvl + 1
          FROM #edge e
          JOIN #seen s ON s.lvl = @lvl AND s.k = e.dk AND s.i = e.di
         WHERE NOT EXISTS (SELECT 1 FROM #seen x WHERE x.k = e.pk AND x.i = e.pi);
        IF @@ROWCOUNT = 0 BREAK;
        IF EXISTS (SELECT 1 FROM #seen WHERE k = @to_kind AND i = @to_id) SET @hit = 1;
        SET @lvl = @lvl + 1;
    END
    IF @hit = 1 AND @loop = N'BLOCK'
    BEGIN
        SET @msg = CONCAT(N'"', @type_name, N'" would create a circular dependency: the other end already depends on this one (',
                          @lvl, N' step(s)).');
        THROW 54708, @msg, 1;
    END
    IF @hit = 1 SET @out_loop = 1;
END
GO

-- Writes one history row with a snapshot of the relationship.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_relationship_history_add
    @relationship_id   BIGINT,
    @action_code       NVARCHAR(20),
    @note              NVARCHAR(1000) = NULL,
    @actor             NVARCHAR(100),
    @actor_employee_id BIGINT         = NULL
AS
BEGIN
    SET NOCOUNT ON;
    INSERT grac_practice.asset_relationship_history
        (relationship_id, organization_id, version_no, action_code, status, snapshot_json, note, actor, actor_employee_id)
    SELECT r.relationship_id, r.organization_id, r.version_no, @action_code, r.status,
           (SELECT r2.relationship_type_code AS typeCode, r2.source_kind AS sourceKind, r2.source_id AS sourceId,
                   r2.target_kind AS targetKind, r2.target_id AS targetId, r2.is_critical AS isCritical,
                   r2.dependency_criticality AS dependencyCriticality, r2.impact_weight AS impactWeight, r2.status AS status,
                   r2.effective_from AS effectiveFrom, r2.effective_to AS effectiveTo, r2.source_code AS sourceCode,
                   r2.confidence_pct AS confidencePct, r2.verification_status AS verificationStatus,
                   r2.owner_employee_id AS ownerEmployeeId, r2.verifier_employee_id AS verifierEmployeeId,
                   r2.evidence_reference AS evidenceReference, r2.change_reference AS changeReference, r2.reason AS reason,
                   r2.in_loop AS inLoop, r2.pending_action AS pendingAction, r2.retirement_accepted AS retirementAccepted
              FROM grac_practice.asset_relationship r2 WHERE r2.relationship_id = r.relationship_id
               FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
           @note, @actor, @actor_employee_id
      FROM grac_practice.asset_relationship r
     WHERE r.relationship_id = @relationship_id;
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    SELECT N'asset-relationship', h.relationship_id, @action_code, NULL, h.snapshot_json, N'Active', @actor
      FROM grac_practice.asset_relationship_history h
     WHERE h.history_id = SCOPE_IDENTITY();
END
GO

-- Active relationships whose effective-to date passed become Inactive
-- (kept for history).
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_relationship_sync
    @organization_id BIGINT,
    @actor           NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @today DATE = CAST(SYSUTCDATETIME() AS DATE);
    DECLARE @ended TABLE (relationship_id BIGINT NOT NULL);
    BEGIN TRAN;
    UPDATE grac_practice.asset_relationship
       SET status = N'INACTIVE', version_no = version_no + 1, updated_by = @actor, updated_dt = SYSUTCDATETIME()
    OUTPUT inserted.relationship_id INTO @ended (relationship_id)
     WHERE organization_id = @organization_id AND status = N'ACTIVE' AND effective_to < @today;
    DECLARE @rid BIGINT;
    DECLARE end_cur CURSOR LOCAL STATIC FOR SELECT relationship_id FROM @ended;
    OPEN end_cur;
    FETCH NEXT FROM end_cur INTO @rid;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        EXEC grac_practice.sp_asset_relationship_history_add @relationship_id = @rid, @action_code = N'EXPIRE',
             @note = N'The effective-to date passed.', @actor = @actor;
        FETCH NEXT FROM end_cur INTO @rid;
    END
    CLOSE end_cur;
    DEALLOCATE end_cur;
    COMMIT;
END
GO
PRINT '440: helpers created.';
GO

-- =====================================================================
-- 4. Writers (5.4.1, 5.4.2; D81-D86)
-- =====================================================================
-- Propose a relationship (new -> Proposed) or change one. A Proposed or
-- Disputed relationship is changed in place. An Active one is changed in
-- place unless it is, or becomes, critical: then the change waits for
-- approval (pending change) and the relationship stays Active as it is.
-- Type and endpoints are fixed once proposed (retire and propose again).
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_relationship_save
    @organization_id         BIGINT,
    @relationship_id         BIGINT         = NULL,
    @relationship_type_code  NVARCHAR(30)   = NULL,
    @source_kind             NVARCHAR(12)   = NULL,
    @source_id               BIGINT         = NULL,
    @target_kind             NVARCHAR(12)   = NULL,
    @target_id               BIGINT         = NULL,
    @is_critical             BIT            = 0,
    @dependency_criticality  NVARCHAR(10)   = NULL,
    @impact_weight           DECIMAL(5, 2)  = NULL,
    @effective_from          DATE           = NULL,
    @effective_to            DATE           = NULL,
    @confidence_pct          INT            = NULL,
    @owner_employee_id       BIGINT         = NULL,
    @verifier_employee_id    BIGINT         = NULL,
    @evidence_reference      NVARCHAR(400)  = NULL,
    @change_reference        NVARCHAR(200)  = NULL,
    @reason                  NVARCHAR(1000) = NULL,
    @expected_record_version BIGINT         = NULL,
    @actor_employee_id       BIGINT         = NULL,
    @actor                   NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    SET @relationship_type_code = UPPER(LTRIM(RTRIM(ISNULL(@relationship_type_code, N''))));
    SET @source_kind = UPPER(LTRIM(RTRIM(ISNULL(@source_kind, N''))));
    SET @target_kind = UPPER(LTRIM(RTRIM(ISNULL(@target_kind, N''))));
    SET @is_critical = ISNULL(@is_critical, 0);
    SET @dependency_criticality = NULLIF(UPPER(LTRIM(RTRIM(@dependency_criticality))), N'');
    SET @evidence_reference = NULLIF(LTRIM(RTRIM(@evidence_reference)), N'');
    SET @change_reference = NULLIF(LTRIM(RTRIM(@change_reference)), N'');
    SET @reason = NULLIF(LTRIM(RTRIM(@reason)), N'');
    DECLARE @today DATE = CAST(SYSUTCDATETIME() AS DATE);
    SET @effective_from = ISNULL(@effective_from, @today);

    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 54701, 'Organization not found.', 1;
    IF @effective_to IS NOT NULL AND @effective_to < @effective_from
        THROW 54714, 'The effective-to date must be on or after the effective-from date.', 1;
    IF @dependency_criticality IS NOT NULL AND @dependency_criticality NOT IN (N'CRITICAL', N'HIGH', N'MEDIUM', N'LOW')
        THROW 54717, 'The dependency criticality is Critical, High, Medium or Low.', 1;
    IF @is_critical = 1 AND @dependency_criticality IS NULL
        THROW 54717, 'Select the dependency criticality of a critical dependency.', 1;
    IF @impact_weight IS NOT NULL AND @impact_weight NOT BETWEEN 0 AND 100
        THROW 54717, 'The impact weight is between 0 and 100.', 1;
    IF @confidence_pct IS NOT NULL AND @confidence_pct NOT BETWEEN 0 AND 100
        THROW 54717, 'The confidence is between 0 and 100.', 1;
    IF (@owner_employee_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee
                                                        WHERE employee_id = @owner_employee_id AND organization_id = @organization_id
                                                          AND status = N'Active'))
       OR (@verifier_employee_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee
                                                              WHERE employee_id = @verifier_employee_id AND organization_id = @organization_id
                                                                AND status = N'Active'))
        THROW 54718, 'The owner and the verifier must be active employees of the organization.', 1;

    DECLARE @loop BIT, @id BIGINT, @result NVARCHAR(20);
    IF @relationship_id IS NULL
    BEGIN
        EXEC grac_practice.sp_asset_relationship_check @organization_id = @organization_id, @relationship_id = NULL,
             @type_code = @relationship_type_code, @source_kind = @source_kind, @source_id = @source_id,
             @target_kind = @target_kind, @target_id = @target_id, @out_loop = @loop OUTPUT;
        BEGIN TRAN;
        INSERT grac_practice.asset_relationship
            (organization_id, relationship_type_code, source_kind, source_id, target_kind, target_id, is_critical,
             dependency_criticality, impact_weight, status, effective_from, effective_to, source_code, confidence_pct,
             owner_employee_id, verifier_employee_id, evidence_reference, change_reference, reason, in_loop,
             proposed_by, proposed_by_employee_id, entered_by)
        VALUES (@organization_id, @relationship_type_code, @source_kind, @source_id, @target_kind, @target_id, @is_critical,
                @dependency_criticality, @impact_weight, N'PROPOSED', @effective_from, @effective_to, N'MANUAL', @confidence_pct,
                @owner_employee_id, @verifier_employee_id, @evidence_reference, @change_reference, @reason, ISNULL(@loop, 0),
                @actor, @actor_employee_id, @actor);
        SET @id = SCOPE_IDENTITY();
        EXEC grac_practice.sp_asset_relationship_history_add @relationship_id = @id, @action_code = N'PROPOSE', @note = @reason,
             @actor = @actor, @actor_employee_id = @actor_employee_id;
        COMMIT;
        SELECT @id AS RelationshipId, N'PROPOSED' AS Result;
        RETURN;
    END

    DECLARE @found BIT = 0, @status NVARCHAR(10), @rv BIGINT, @was_critical BIT, @pending NVARCHAR(10);
    SELECT @found = 1, @status = status, @rv = CONVERT(BIGINT, record_version), @was_critical = is_critical, @pending = pending_action
      FROM grac_practice.asset_relationship WHERE relationship_id = @relationship_id AND organization_id = @organization_id;
    IF @found = 0 THROW 54709, 'Relationship not found for this organization.', 1;
    IF @expected_record_version IS NOT NULL AND @expected_record_version <> @rv
        THROW 54710, 'The relationship was changed by someone else; reload it and try again.', 1;
    IF @status IN (N'INACTIVE', N'RETIRED')
        THROW 54711, 'An inactive or retired relationship is kept for history and cannot be changed.', 1;
    IF @pending IS NOT NULL
        THROW 54712, 'A change of this relationship is waiting for approval; approve, reject or withdraw it first.', 1;
    IF @status = N'ACTIVE' AND @reason IS NULL
        THROW 54713, 'Enter the reason for changing an active relationship.', 1;

    BEGIN TRAN;
    IF @status = N'ACTIVE' AND (@was_critical = 1 OR @is_critical = 1)
    BEGIN
        UPDATE grac_practice.asset_relationship
           SET pending_action = N'UPDATE', pending_reason = @reason, pending_by = @actor, pending_by_employee_id = @actor_employee_id,
               pending_dt = SYSUTCDATETIME(),
               pending_json = (SELECT @is_critical AS isCritical, @dependency_criticality AS dependencyCriticality,
                                      @impact_weight AS impactWeight, @effective_from AS effectiveFrom, @effective_to AS effectiveTo,
                                      @confidence_pct AS confidencePct, @owner_employee_id AS ownerEmployeeId,
                                      @verifier_employee_id AS verifierEmployeeId, @evidence_reference AS evidenceReference,
                                      @change_reference AS changeReference, @reason AS reason
                                  FOR JSON PATH, INCLUDE_NULL_VALUES, WITHOUT_ARRAY_WRAPPER),
               updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE relationship_id = @relationship_id;
        EXEC grac_practice.sp_asset_relationship_history_add @relationship_id = @relationship_id, @action_code = N'CHANGE_REQUEST',
             @note = @reason, @actor = @actor, @actor_employee_id = @actor_employee_id;
        SET @result = N'PENDING_APPROVAL';
    END
    ELSE
    BEGIN
        UPDATE grac_practice.asset_relationship
           SET is_critical = @is_critical, dependency_criticality = @dependency_criticality, impact_weight = @impact_weight,
               effective_from = @effective_from, effective_to = @effective_to, confidence_pct = @confidence_pct,
               owner_employee_id = @owner_employee_id, verifier_employee_id = @verifier_employee_id,
               evidence_reference = @evidence_reference, change_reference = @change_reference, reason = @reason,
               version_no = version_no + 1, updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE relationship_id = @relationship_id;
        EXEC grac_practice.sp_asset_relationship_history_add @relationship_id = @relationship_id, @action_code = N'UPDATE',
             @note = @reason, @actor = @actor, @actor_employee_id = @actor_employee_id;
        SET @result = N'UPDATED';
    END
    COMMIT;
    SELECT @relationship_id AS RelationshipId, @result AS Result;
END
GO

-- Actions (D82-D86):
--   APPROVE            Proposed -> Active (checks repeated); or applies the
--                      pending change / retirement. A critical relationship
--                      or change is approved by another person.
--   REJECT             a proposal (-> Retired) or a pending change; note.
--   WITHDRAW           the proposer withdraws the proposal (-> Retired) or
--                      the requester the pending change.
--   DISPUTE            Active -> Disputed; note.
--   CONFIRM            Disputed -> Active; note.
--   RETIRE             Active / Disputed / Inactive -> Retired, effective to
--                      today at the latest; an active critical one waits for
--                      approval; note.
--   ACCEPT_RETIREMENT  an active critical dependency is accepted as an
--                      exception for the retirement of the CI it relies on.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_relationship_action
    @organization_id         BIGINT,
    @relationship_id         BIGINT,
    @action                  NVARCHAR(20),
    @note                    NVARCHAR(1000) = NULL,
    @expected_record_version BIGINT         = NULL,
    @actor_employee_id       BIGINT         = NULL,
    @actor                   NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    SET @action = UPPER(LTRIM(RTRIM(ISNULL(@action, N''))));
    SET @note = NULLIF(LTRIM(RTRIM(@note)), N'');
    DECLARE @today DATE = CAST(SYSUTCDATETIME() AS DATE);

    DECLARE @found BIT = 0, @status NVARCHAR(10), @rv BIGINT, @critical BIT, @pending NVARCHAR(10), @pending_json NVARCHAR(MAX),
            @pending_by NVARCHAR(100), @pending_emp BIGINT, @pending_reason NVARCHAR(1000), @proposed_by NVARCHAR(100),
            @proposed_emp BIGINT, @type NVARCHAR(30), @sk NVARCHAR(12), @si BIGINT, @tk NVARCHAR(12), @ti BIGINT;
    SELECT @found = 1, @status = status, @rv = CONVERT(BIGINT, record_version), @critical = is_critical, @pending = pending_action,
           @pending_json = pending_json, @pending_by = pending_by, @pending_emp = pending_by_employee_id,
           @pending_reason = pending_reason, @proposed_by = proposed_by, @proposed_emp = proposed_by_employee_id,
           @type = relationship_type_code, @sk = source_kind, @si = source_id, @tk = target_kind, @ti = target_id
      FROM grac_practice.asset_relationship WHERE relationship_id = @relationship_id AND organization_id = @organization_id;
    IF @found = 0 THROW 54709, 'Relationship not found for this organization.', 1;
    IF @action NOT IN (N'APPROVE', N'REJECT', N'WITHDRAW', N'DISPUTE', N'CONFIRM', N'RETIRE', N'ACCEPT_RETIREMENT')
        THROW 54715, 'The action is Approve, Reject, Withdraw, Dispute, Confirm, Retire or Accept for retirement.', 1;
    IF @expected_record_version IS NOT NULL AND @expected_record_version <> @rv
        THROW 54710, 'The relationship was changed by someone else; reload it and try again.', 1;
    IF @action IN (N'REJECT', N'DISPUTE', N'CONFIRM', N'RETIRE', N'ACCEPT_RETIREMENT') AND @note IS NULL
        THROW 54713, 'Enter the note for this action.', 1;

    DECLARE @result NVARCHAR(20), @loop BIT, @hist NVARCHAR(20) = @action;
    BEGIN TRAN;
    IF @action = N'APPROVE' AND @status = N'PROPOSED'
    BEGIN
        IF @critical = 1 AND (@proposed_by = @actor OR (@proposed_emp IS NOT NULL AND @proposed_emp = @actor_employee_id))
            THROW 54716, 'Segregation of duties: the person who proposed a critical relationship cannot approve it.', 1;
        EXEC grac_practice.sp_asset_relationship_check @organization_id = @organization_id, @relationship_id = @relationship_id,
             @type_code = @type, @source_kind = @sk, @source_id = @si, @target_kind = @tk, @target_id = @ti, @out_loop = @loop OUTPUT;
        UPDATE grac_practice.asset_relationship
           SET status = N'ACTIVE', verification_status = N'VERIFIED', in_loop = ISNULL(@loop, 0), approved_by = @actor,
               approved_by_employee_id = @actor_employee_id, approved_dt = SYSUTCDATETIME(), status_note = @note,
               updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE relationship_id = @relationship_id;
        SET @result = N'ACTIVE';
    END
    ELSE IF @action = N'APPROVE' AND @pending IS NOT NULL
    BEGIN
        IF @pending_by = @actor OR (@pending_emp IS NOT NULL AND @pending_emp = @actor_employee_id)
            THROW 54716, 'Segregation of duties: the person who requested the change cannot approve it.', 1;
        IF @pending = N'UPDATE'
        BEGIN
            UPDATE r
               SET is_critical = ISNULL(j.isCritical, 0), dependency_criticality = j.dependencyCriticality, impact_weight = j.impactWeight,
                   effective_from = j.effectiveFrom, effective_to = j.effectiveTo, confidence_pct = j.confidencePct,
                   owner_employee_id = j.ownerEmployeeId, verifier_employee_id = j.verifierEmployeeId,
                   evidence_reference = j.evidenceReference, change_reference = j.changeReference, reason = j.reason,
                   version_no = version_no + 1
              FROM grac_practice.asset_relationship r
             CROSS APPLY OPENJSON(@pending_json) WITH (
                    isCritical BIT, dependencyCriticality NVARCHAR(10), impactWeight DECIMAL(5, 2), effectiveFrom DATE,
                    effectiveTo DATE, confidencePct INT, ownerEmployeeId BIGINT, verifierEmployeeId BIGINT,
                    evidenceReference NVARCHAR(400), changeReference NVARCHAR(200), reason NVARCHAR(1000)) j
             WHERE r.relationship_id = @relationship_id;
            SET @result = N'UPDATED';
            SET @hist = N'APPROVE_CHANGE';
        END
        ELSE
        BEGIN
            UPDATE grac_practice.asset_relationship
               SET status = N'RETIRED', status_note = @pending_reason, version_no = version_no + 1,
                   effective_to = CASE WHEN effective_to IS NULL OR effective_to > @today THEN
                                           CASE WHEN effective_from > @today THEN effective_from ELSE @today END
                                       ELSE effective_to END
             WHERE relationship_id = @relationship_id;
            SET @result = N'RETIRED';
            SET @hist = N'APPROVE_RETIRE';
        END
        UPDATE grac_practice.asset_relationship
           SET pending_action = NULL, pending_json = NULL, pending_reason = NULL, pending_by = NULL, pending_by_employee_id = NULL,
               pending_dt = NULL, approved_by = @actor, approved_by_employee_id = @actor_employee_id, approved_dt = SYSUTCDATETIME(),
               updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE relationship_id = @relationship_id;
    END
    ELSE IF @action IN (N'REJECT', N'WITHDRAW') AND (@status = N'PROPOSED' OR @pending IS NOT NULL)
    BEGIN
        IF @action = N'WITHDRAW'
           AND ((@pending IS NOT NULL AND ISNULL(@pending_by, N'') <> @actor)
                OR (@pending IS NULL AND @proposed_by <> @actor))
            THROW 54716, 'Only the person who proposed the relationship or requested the change can withdraw it.', 1;
        IF @pending IS NOT NULL
        BEGIN
            UPDATE grac_practice.asset_relationship
               SET pending_action = NULL, pending_json = NULL, pending_reason = NULL, pending_by = NULL, pending_by_employee_id = NULL,
                   pending_dt = NULL, status_note = ISNULL(@note, N'Withdrawn by the requester.'),
                   updated_by = @actor, updated_dt = SYSUTCDATETIME()
             WHERE relationship_id = @relationship_id;
            SET @result = @status;
            SET @hist = CONCAT(@action, N'_CHANGE');
        END
        ELSE
        BEGIN
            UPDATE grac_practice.asset_relationship
               SET status = N'RETIRED', status_note = ISNULL(@note, N'Withdrawn by the proposer.'), version_no = version_no + 1,
                   updated_by = @actor, updated_dt = SYSUTCDATETIME()
             WHERE relationship_id = @relationship_id;
            SET @result = N'RETIRED';
        END
    END
    ELSE IF @action = N'DISPUTE' AND @status = N'ACTIVE' AND @pending IS NULL
    BEGIN
        UPDATE grac_practice.asset_relationship
           SET status = N'DISPUTED', status_note = @note, version_no = version_no + 1, updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE relationship_id = @relationship_id;
        SET @result = N'DISPUTED';
    END
    ELSE IF @action = N'CONFIRM' AND @status = N'DISPUTED'
    BEGIN
        UPDATE grac_practice.asset_relationship
           SET status = N'ACTIVE', verification_status = N'VERIFIED', status_note = @note, version_no = version_no + 1,
               approved_by = @actor, approved_by_employee_id = @actor_employee_id, approved_dt = SYSUTCDATETIME(),
               updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE relationship_id = @relationship_id;
        SET @result = N'ACTIVE';
    END
    ELSE IF @action = N'RETIRE' AND @status IN (N'ACTIVE', N'DISPUTED', N'INACTIVE') AND @pending IS NULL
    BEGIN
        IF @status = N'ACTIVE' AND @critical = 1
        BEGIN
            UPDATE grac_practice.asset_relationship
               SET pending_action = N'RETIRE', pending_json = NULL, pending_reason = @note, pending_by = @actor,
                   pending_by_employee_id = @actor_employee_id, pending_dt = SYSUTCDATETIME(),
                   updated_by = @actor, updated_dt = SYSUTCDATETIME()
             WHERE relationship_id = @relationship_id;
            SET @result = N'PENDING_APPROVAL';
            SET @hist = N'RETIRE_REQUEST';
        END
        ELSE
        BEGIN
            UPDATE grac_practice.asset_relationship
               SET status = N'RETIRED', status_note = @note, version_no = version_no + 1,
                   effective_to = CASE WHEN effective_to IS NULL OR effective_to > @today THEN
                                           CASE WHEN effective_from > @today THEN effective_from ELSE @today END
                                       ELSE effective_to END,
                   updated_by = @actor, updated_dt = SYSUTCDATETIME()
             WHERE relationship_id = @relationship_id;
            SET @result = N'RETIRED';
        END
    END
    ELSE IF @action = N'ACCEPT_RETIREMENT' AND @status = N'ACTIVE' AND @critical = 1
    BEGIN
        UPDATE grac_practice.asset_relationship
           SET retirement_accepted = 1, retirement_note = @note, retirement_accepted_by = @actor,
               retirement_accepted_dt = SYSUTCDATETIME(), updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE relationship_id = @relationship_id;
        SET @result = N'ACCEPTED';
    END
    ELSE
        THROW 54715, 'This action is not available for the relationship in its current status.', 1;

    EXEC grac_practice.sp_asset_relationship_history_add @relationship_id = @relationship_id, @action_code = @hist, @note = @note,
         @actor = @actor, @actor_employee_id = @actor_employee_id;
    COMMIT;
    SELECT @relationship_id AS RelationshipId, @result AS Result;
END
GO
PRINT '440: writers created.';
GO

-- =====================================================================
-- 5. Impact analysis (5.4.2, 5.5.2; D84)
-- =====================================================================
-- DOWNSTREAM: the CIs affected when this CI fails (those that depend on it,
-- level by level). UPSTREAM: the CIs this one relies on. Only Active,
-- currently effective relationships of types that carry impact are walked;
-- @preview_relationship_id adds one Proposed relationship (or the pending
-- change of an Active one, by its current endpoints) to preview its effect.
-- Each CI appears once, at its nearest level (no double counting); depth
-- 1-10; @critical_only walks critical dependencies only.
-- 1. affected / supporting CIs  2. summary.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_ci_impact
    @organization_id         BIGINT,
    @ci_kind                 NVARCHAR(12),
    @ci_id                   BIGINT,
    @direction               NVARCHAR(10)  = N'DOWNSTREAM',
    @max_depth               INT           = 5,
    @critical_only           BIT           = 0,
    @preview_relationship_id BIGINT        = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @ci_kind = UPPER(LTRIM(RTRIM(ISNULL(@ci_kind, N''))));
    SET @direction = UPPER(LTRIM(RTRIM(ISNULL(@direction, N'DOWNSTREAM'))));
    SET @max_depth = CASE WHEN ISNULL(@max_depth, 5) < 1 THEN 1 WHEN @max_depth > 10 THEN 10 ELSE @max_depth END;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 54701, 'Organization not found.', 1;
    IF @direction NOT IN (N'DOWNSTREAM', N'UPSTREAM')
       OR NOT EXISTS (SELECT 1 FROM grac_practice.fn_asset_ci_catalog(@organization_id) WHERE CiKind = @ci_kind AND CiId = @ci_id)
        THROW 54720, 'Select a configuration item of this organization and the direction (downstream or upstream).', 1;

    CREATE TABLE #edge (rel BIGINT NOT NULL, type_code NVARCHAR(30) NOT NULL, crit BIT NOT NULL,
                        dk NVARCHAR(12) NOT NULL, di BIGINT NOT NULL, pk NVARCHAR(12) NOT NULL, pi BIGINT NOT NULL);
    INSERT #edge (rel, type_code, crit, dk, di, pk, pi)
    SELECT RelationshipId, TypeCode, IsCritical, DependentKind, DependentId, ProviderKind, ProviderId
      FROM grac_practice.fn_asset_relationship_edges(@organization_id, 1)
     WHERE ISNULL(@critical_only, 0) = 0 OR IsCritical = 1;
    IF @preview_relationship_id IS NOT NULL
        INSERT #edge (rel, type_code, crit, dk, di, pk, pi)
        SELECT e.RelationshipId, e.TypeCode, e.IsCritical, e.DependentKind, e.DependentId, e.ProviderKind, e.ProviderId
          FROM grac_practice.fn_asset_relationship_edges(@organization_id, 0) e
         WHERE e.RelationshipId = @preview_relationship_id
           AND NOT EXISTS (SELECT 1 FROM #edge x WHERE x.rel = e.RelationshipId);

    CREATE TABLE #seen (k NVARCHAR(12) NOT NULL, i BIGINT NOT NULL, lvl INT NOT NULL, rel BIGINT NULL,
                        from_k NVARCHAR(12) NULL, from_i BIGINT NULL, PRIMARY KEY (k, i));
    INSERT #seen (k, i, lvl) VALUES (@ci_kind, @ci_id, 0);
    DECLARE @lvl INT = 0;
    WHILE @lvl < @max_depth
    BEGIN
        -- one row per newly reached CI: the lowest relationship id reaching it from this level
        INSERT #seen (k, i, lvl, rel, from_k, from_i)
        SELECT x.k, x.i, @lvl + 1, x.rel, x.from_k, x.from_i
          FROM (SELECT CASE WHEN @direction = N'DOWNSTREAM' THEN e.dk ELSE e.pk END AS k,
                       CASE WHEN @direction = N'DOWNSTREAM' THEN e.di ELSE e.pi END AS i,
                       e.rel, s.k AS from_k, s.i AS from_i,
                       ROW_NUMBER() OVER (PARTITION BY CASE WHEN @direction = N'DOWNSTREAM' THEN e.dk ELSE e.pk END,
                                                       CASE WHEN @direction = N'DOWNSTREAM' THEN e.di ELSE e.pi END
                                          ORDER BY e.crit DESC, e.rel) AS rn
                  FROM #edge e
                  JOIN #seen s ON s.lvl = @lvl
                              AND ((@direction = N'DOWNSTREAM' AND s.k = e.pk AND s.i = e.pi)
                                   OR (@direction = N'UPSTREAM' AND s.k = e.dk AND s.i = e.di))) x
         WHERE x.rn = 1
           AND NOT EXISTS (SELECT 1 FROM #seen z WHERE z.k = x.k AND z.i = x.i);
        IF @@ROWCOUNT = 0 BREAK;
        SET @lvl = @lvl + 1;
    END

    SELECT s.k AS CiKind, s.i AS CiId, c.CiName, c.CiClass, c.CiStatus, s.lvl AS ImpactLevel, s.rel AS ViaRelationshipId,
           e.type_code AS ViaTypeCode,
           CASE WHEN @direction = N'DOWNSTREAM' THEN
                     CASE t.dependent_side WHEN N'SOURCE' THEN t.type_name ELSE t.inverse_label END
                ELSE CASE t.dependent_side WHEN N'SOURCE' THEN t.inverse_label ELSE t.type_name END END AS ViaLabel,
           e.crit AS ViaCritical, s.from_k AS FromKind, s.from_i AS FromId, fc.CiName AS FromName,
           CAST(CASE WHEN e.rel = @preview_relationship_id THEN 1 ELSE 0 END AS BIT) AS ViaPreview
      FROM #seen s
      JOIN #edge e ON e.rel = s.rel
      JOIN grac_practice.asset_relationship_type t ON t.type_code = e.type_code
      LEFT JOIN grac_practice.fn_asset_ci_catalog(@organization_id) c ON c.CiKind = s.k AND c.CiId = s.i
      LEFT JOIN grac_practice.fn_asset_ci_catalog(@organization_id) fc ON fc.CiKind = s.from_k AND fc.CiId = s.from_i
     WHERE s.lvl > 0
     ORDER BY s.lvl, c.CiKind, c.CiName;

    SELECT @ci_kind AS CiKind, @ci_id AS CiId, (SELECT CiName FROM grac_practice.fn_asset_ci_catalog(@organization_id)
                                                  WHERE CiKind = @ci_kind AND CiId = @ci_id) AS CiName,
           @direction AS Direction, @max_depth AS MaxDepth,
           (SELECT COUNT(*) FROM #seen WHERE lvl > 0) AS ReachedCount,
           (SELECT COUNT(*) FROM #seen s JOIN #edge e ON e.rel = s.rel WHERE s.lvl > 0 AND e.crit = 1) AS CriticalCount,
           (SELECT MAX(lvl) FROM #seen) AS DeepestLevel;
END
GO
PRINT '440: impact analysis created.';
GO

-- =====================================================================
-- 6. Readers
-- =====================================================================
-- 1. relationship types  2. active employees.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_relationship_config_get
    @organization_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 54701, 'Organization not found.', 1;
    SELECT type_code AS TypeCode, type_name AS TypeName, inverse_label AS InverseLabel, brd_pair AS BrdPair, description AS Description,
           source_kinds AS SourceKinds, target_kinds AS TargetKinds, cardinality AS Cardinality, loop_rule AS LoopRule,
           dependent_side AS DependentSide, is_active AS IsActive, inactive_reason AS InactiveReason
      FROM grac_practice.asset_relationship_type
     ORDER BY display_order;
    SELECT employee_id AS EmployeeId, employee_name AS EmployeeName
      FROM grac_practice.organization_employee
     WHERE organization_id = @organization_id AND status = N'Active'
     ORDER BY employee_name;
END
GO

-- CI picker: up to @top configuration items of a kind (or every kind)
-- whose name or class matches.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_ci_lookup
    @organization_id BIGINT,
    @ci_kind         NVARCHAR(12)  = NULL,
    @search          NVARCHAR(200) = NULL,
    @top             INT           = 50
AS
BEGIN
    SET NOCOUNT ON;
    SET @ci_kind = NULLIF(UPPER(LTRIM(RTRIM(@ci_kind))), N'');
    SET @search = NULLIF(LTRIM(RTRIM(@search)), N'');
    SET @top = CASE WHEN ISNULL(@top, 50) < 1 THEN 50 WHEN @top > 200 THEN 200 ELSE @top END;
    SELECT TOP (@top) c.CiKind, c.CiId, c.CiName, c.CiClass, c.CiStatus, c.IsUsable
      FROM grac_practice.fn_asset_ci_catalog(@organization_id) c
     WHERE (@ci_kind IS NULL OR c.CiKind = @ci_kind)
       AND (@search IS NULL OR c.CiName LIKE N'%' + @search + N'%' OR c.CiClass LIKE N'%' + @search + N'%')
     ORDER BY c.IsUsable DESC, c.CiName;
END
GO

-- Relationships (Inactive ones refreshed first). @status: NULL = current
-- (proposed, active, disputed), ALL, or one status. @ci_kind / @ci_id: either
-- end. @pending_only: proposals and pending changes waiting for approval.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_relationships
    @organization_id BIGINT,
    @ci_kind         NVARCHAR(12)  = NULL,
    @ci_id           BIGINT        = NULL,
    @type_code       NVARCHAR(30)  = NULL,
    @status          NVARCHAR(10)  = NULL,
    @critical_only   BIT           = 0,
    @pending_only    BIT           = 0,
    @search          NVARCHAR(200) = NULL,
    @page_number     INT           = 1,
    @page_size       INT           = 25,
    @actor           NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 54701, 'Organization not found.', 1;
    SET @ci_kind = NULLIF(UPPER(LTRIM(RTRIM(@ci_kind))), N'');
    SET @type_code = NULLIF(UPPER(LTRIM(RTRIM(@type_code))), N'');
    SET @status = NULLIF(UPPER(LTRIM(RTRIM(@status))), N'');
    SET @search = NULLIF(LTRIM(RTRIM(@search)), N'');
    SET @page_number = CASE WHEN ISNULL(@page_number, 1) < 1 THEN 1 ELSE @page_number END;
    SET @page_size = CASE WHEN ISNULL(@page_size, 25) < 1 THEN 25 WHEN @page_size > 200 THEN 200 ELSE @page_size END;
    EXEC grac_practice.sp_asset_relationship_sync @organization_id = @organization_id, @actor = @actor;

    SELECT r.relationship_id AS RelationshipId, r.relationship_type_code AS TypeCode, t.type_name AS TypeName,
           t.inverse_label AS InverseLabel, t.dependent_side AS DependentSide,
           r.source_kind AS SourceKind, r.source_id AS SourceId, sc.CiName AS SourceName, sc.CiClass AS SourceClass,
           sc.CiStatus AS SourceStatus, r.target_kind AS TargetKind, r.target_id AS TargetId, tc.CiName AS TargetName,
           tc.CiClass AS TargetClass, tc.CiStatus AS TargetStatus, r.is_critical AS IsCritical,
           r.dependency_criticality AS DependencyCriticality, r.impact_weight AS ImpactWeight, r.status AS Status,
           r.effective_from AS EffectiveFrom, r.effective_to AS EffectiveTo, r.source_code AS SourceCode,
           r.confidence_pct AS ConfidencePct, r.verification_status AS VerificationStatus, ow.employee_name AS OwnerName,
           vf.employee_name AS VerifierName, r.in_loop AS InLoop, r.version_no AS VersionNo, r.pending_action AS PendingAction,
           r.pending_reason AS PendingReason, r.pending_by AS PendingBy, r.retirement_accepted AS RetirementAccepted,
           r.proposed_by AS ProposedBy, r.approved_by AS ApprovedBy, r.approved_dt AS ApprovedDt, r.status_note AS StatusNote,
           CONVERT(BIGINT, r.record_version) AS RecordVersion,
           COUNT(*) OVER () AS TotalRows
      FROM grac_practice.asset_relationship r
      JOIN grac_practice.asset_relationship_type t ON t.type_code = r.relationship_type_code
      LEFT JOIN grac_practice.fn_asset_ci_catalog(@organization_id) sc ON sc.CiKind = r.source_kind AND sc.CiId = r.source_id
      LEFT JOIN grac_practice.fn_asset_ci_catalog(@organization_id) tc ON tc.CiKind = r.target_kind AND tc.CiId = r.target_id
      LEFT JOIN grac_practice.organization_employee ow ON ow.employee_id = r.owner_employee_id
      LEFT JOIN grac_practice.organization_employee vf ON vf.employee_id = r.verifier_employee_id
     WHERE r.organization_id = @organization_id
       AND (@ci_kind IS NULL OR @ci_id IS NULL
            OR (r.source_kind = @ci_kind AND r.source_id = @ci_id) OR (r.target_kind = @ci_kind AND r.target_id = @ci_id))
       AND (@type_code IS NULL OR r.relationship_type_code = @type_code)
       AND ((@status IS NULL AND r.status IN (N'PROPOSED', N'ACTIVE', N'DISPUTED')) OR @status = N'ALL' OR r.status = @status)
       AND (ISNULL(@critical_only, 0) = 0 OR r.is_critical = 1)
       AND (ISNULL(@pending_only, 0) = 0 OR r.status = N'PROPOSED' OR r.pending_action IS NOT NULL)
       AND (@search IS NULL OR sc.CiName LIKE N'%' + @search + N'%' OR tc.CiName LIKE N'%' + @search + N'%')
     ORDER BY CASE WHEN r.status = N'PROPOSED' OR r.pending_action IS NOT NULL THEN 0 WHEN r.status = N'DISPUTED' THEN 1
                   WHEN r.status = N'ACTIVE' THEN 2 ELSE 3 END,
              r.is_critical DESC, sc.CiName, t.display_order, tc.CiName
    OFFSET (@page_number - 1) * @page_size ROWS FETCH NEXT @page_size ROWS ONLY;
END
GO

-- One relationship: 1. the relationship  2. history.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_relationship_get
    @organization_id BIGINT,
    @relationship_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.asset_relationship
                    WHERE relationship_id = @relationship_id AND organization_id = @organization_id)
        THROW 54709, 'Relationship not found for this organization.', 1;
    SELECT r.relationship_id AS RelationshipId, r.relationship_type_code AS TypeCode, t.type_name AS TypeName,
           t.inverse_label AS InverseLabel, t.dependent_side AS DependentSide, r.source_kind AS SourceKind, r.source_id AS SourceId,
           sc.CiName AS SourceName, sc.CiClass AS SourceClass, sc.CiStatus AS SourceStatus, r.target_kind AS TargetKind,
           r.target_id AS TargetId, tc.CiName AS TargetName, tc.CiClass AS TargetClass, tc.CiStatus AS TargetStatus,
           r.is_critical AS IsCritical, r.dependency_criticality AS DependencyCriticality, r.impact_weight AS ImpactWeight,
           r.status AS Status, r.effective_from AS EffectiveFrom, r.effective_to AS EffectiveTo, r.source_code AS SourceCode,
           r.confidence_pct AS ConfidencePct, r.verification_status AS VerificationStatus, r.owner_employee_id AS OwnerEmployeeId,
           ow.employee_name AS OwnerName, r.verifier_employee_id AS VerifierEmployeeId, vf.employee_name AS VerifierName,
           r.evidence_reference AS EvidenceReference, r.change_reference AS ChangeReference, r.reason AS Reason, r.in_loop AS InLoop,
           r.version_no AS VersionNo, r.proposed_by AS ProposedBy, r.proposed_dt AS ProposedDt, r.approved_by AS ApprovedBy,
           r.approved_dt AS ApprovedDt, r.pending_action AS PendingAction, r.pending_json AS PendingJson,
           r.pending_reason AS PendingReason, r.pending_by AS PendingBy, r.pending_dt AS PendingDt,
           r.retirement_accepted AS RetirementAccepted, r.retirement_note AS RetirementNote,
           r.retirement_accepted_by AS RetirementAcceptedBy, r.retirement_accepted_dt AS RetirementAcceptedDt,
           r.status_note AS StatusNote, CONVERT(BIGINT, r.record_version) AS RecordVersion
      FROM grac_practice.asset_relationship r
      JOIN grac_practice.asset_relationship_type t ON t.type_code = r.relationship_type_code
      LEFT JOIN grac_practice.fn_asset_ci_catalog(@organization_id) sc ON sc.CiKind = r.source_kind AND sc.CiId = r.source_id
      LEFT JOIN grac_practice.fn_asset_ci_catalog(@organization_id) tc ON tc.CiKind = r.target_kind AND tc.CiId = r.target_id
      LEFT JOIN grac_practice.organization_employee ow ON ow.employee_id = r.owner_employee_id
      LEFT JOIN grac_practice.organization_employee vf ON vf.employee_id = r.verifier_employee_id
     WHERE r.relationship_id = @relationship_id;
    SELECT h.history_id AS HistoryId, h.version_no AS VersionNo, h.action_code AS ActionCode, h.status AS Status,
           h.note AS Note, h.actor AS Actor, e.employee_name AS ActorName, h.entered_dt AS EnteredDt, h.snapshot_json AS SnapshotJson
      FROM grac_practice.asset_relationship_history h
      LEFT JOIN grac_practice.organization_employee e ON e.employee_id = h.actor_employee_id
     WHERE h.relationship_id = @relationship_id
     ORDER BY h.history_id DESC;
END
GO
PRINT '440: readers created.';
GO

-- =====================================================================
-- 7. Lifecycle gate: sp_asset_lifecycle_transition (435 body, 440 lines marked)
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_lifecycle_transition
    @organization_id         BIGINT,
    @asset_id                BIGINT,
    @to_status_code          NVARCHAR(60),
    @reason_text             NVARCHAR(1000) = NULL,
    @reference_text          NVARCHAR(400)  = NULL,
    @evidence_text           NVARCHAR(1000) = NULL,
    @expected_record_version BIGINT         = NULL,
    @actor_employee_id       BIGINT         = NULL,
    @actor                   NVARCHAR(100)  = N'system',
    @out_change_id           BIGINT         = NULL OUTPUT,
    @out_result              NVARCHAR(20)   = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    SET @to_status_code = UPPER(LTRIM(RTRIM(ISNULL(@to_status_code, N''))));
    SET @reason_text = NULLIF(LTRIM(RTRIM(@reason_text)), N'');
    SET @reference_text = NULLIF(LTRIM(RTRIM(@reference_text)), N'');
    SET @evidence_text = NULLIF(LTRIM(RTRIM(@evidence_text)), N'');

    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 54970, 'Organization not found.', 1;

    DECLARE @found BIT = 0, @rv BIGINT, @from NVARCHAR(60), @template_id BIGINT, @owner_id BIGINT;
    SELECT @found = 1, @rv = CONVERT(BIGINT, a.record_version), @from = COALESCE(cs.status_code, ls.status_code),
           @template_id = a.template_id, @owner_id = a.owner_id
      FROM grac_practice.organization_dependency_asset a
      LEFT JOIN grac_practice.entity_status_master cs ON cs.entity_status_id = a.current_status_id
      LEFT JOIN grac_practice.asset_legacy_status_map ls ON ls.legacy_lifecycle_status = ISNULL(a.lifecycle_status, N'Commissioned')
     WHERE a.asset_id = @asset_id AND a.organization_id = @organization_id;
    IF @found = 0 THROW 54971, 'Asset not found for this organization.', 1;
    IF @expected_record_version IS NOT NULL AND @expected_record_version <> @rv
        THROW 54972, 'This asset was changed by someone else. Reload it and try again.', 1;
    IF EXISTS (SELECT 1 FROM grac_practice.asset_lifecycle_change WHERE asset_id = @asset_id AND change_status = N'PENDING_APPROVAL')
        THROW 54973, 'A lifecycle change for this asset is awaiting approval. Approve, reject or cancel it first.', 1;
    IF @from IN (N'DISPOSED', N'ARCHIVED') AND @to_status_code = N'ACTIVE'
        THROW 54975, 'A disposed or archived asset cannot return to Active (BRD 5.4.3 / 19.9). Register a replacement asset instead.', 1;

    DECLARE @rule_id INT, @req_reason BIT, @req_approval BIT, @ref_label NVARCHAR(200), @req_evidence BIT,
            @req_form BIT, @req_owner BIT;
    SELECT TOP 1 @rule_id = r.transition_rule_id, @req_reason = r.requires_reason, @req_approval = r.requires_approval,
           @ref_label = g.reference_label, @req_evidence = g.requires_evidence, @req_form = g.requires_registered_form,
           @req_owner = g.requires_owner
      FROM grac_practice.entity_state_transition_rule r
      JOIN grac_practice.asset_lifecycle_transition_gate g ON g.transition_rule_id = r.transition_rule_id
     WHERE r.entity_type = N'Asset' AND r.is_active = 1 AND r.actor_role_code IS NULL
       AND r.from_status_code = @from AND r.to_status_code = @to_status_code;
    IF @rule_id IS NULL
    BEGIN
        DECLARE @allowed NVARCHAR(1000) = (
            SELECT STRING_AGG(s.status_name, N', ') WITHIN GROUP (ORDER BY s.display_order)
              FROM grac_practice.entity_state_transition_rule r
              JOIN grac_practice.asset_lifecycle_transition_gate g ON g.transition_rule_id = r.transition_rule_id
              JOIN grac_practice.entity_status_master s ON s.entity_type = N'Asset' AND s.status_code = r.to_status_code
             WHERE r.entity_type = N'Asset' AND r.is_active = 1 AND r.actor_role_code IS NULL AND r.from_status_code = @from);
        DECLARE @from_name NVARCHAR(120) = (SELECT status_name FROM grac_practice.entity_status_master
                                             WHERE entity_type = N'Asset' AND status_code = @from);
        DECLARE @target_name NVARCHAR(120) = (SELECT status_name FROM grac_practice.entity_status_master
                                               WHERE entity_type = N'Asset' AND status_code = @to_status_code);
        DECLARE @msg NVARCHAR(2048) = CONCAT(N'This asset cannot move from ', ISNULL(@from_name, @from), N' to ',
            ISNULL(@target_name, @to_status_code), N'. Configured moves: ', ISNULL(@allowed, N'none'), N'.');
        THROW 54974, @msg, 1;
    END

    IF @req_form = 1 AND @template_id IS NULL
        THROW 54979, 'Open the asset and save it on its form template first, so its required fields are validated.', 1;
    IF @req_owner = 1 AND @owner_id IS NULL
        THROW 54980, 'Set the asset owner first (identity, owner and source validation).', 1;
    IF @req_reason = 1 AND @reason_text IS NULL
        THROW 54976, 'A reason is required for this change.', 1;
    IF @ref_label IS NOT NULL AND @reference_text IS NULL
    BEGIN
        DECLARE @ref_msg NVARCHAR(400) = CONCAT(N'Enter the ', LOWER(@ref_label), N'.');
        THROW 54977, @ref_msg, 1;
    END
    IF @req_evidence = 1 AND @evidence_text IS NULL
        THROW 54978, 'Evidence is required for this change (document number, report or link).', 1;
    -- 435: required coverage configured to block activation (5.2.14, D42).
    IF @to_status_code = N'ACTIVE'
    BEGIN
        DECLARE @gaps NVARCHAR(1000) = (SELECT STRING_AGG(g.CoverageTypeLabel, N', ')
                                          FROM grac_practice.fn_asset_coverage_gaps(@organization_id) g
                                         WHERE g.AssetId = @asset_id AND g.MissingAction = N'BLOCK_ACTIVATION');
        IF @gaps IS NOT NULL
        BEGIN
            DECLARE @gap_msg NVARCHAR(1200) = CONCAT(N'The asset cannot become Active without its required coverage: ', @gaps,
                                                     N'. Map it on an active contract (Contracts) first.');
            THROW 54560, @gap_msg, 1;
        END
    END
    -- 440: retiring the asset is blocked while active critical relationships
    -- rely on it and were not accepted for its retirement (5.4.2, D86).
    IF @to_status_code IN (N'SANITIZATION_PENDING', N'DISPOSAL_APPROVAL', N'DISPOSED', N'ARCHIVED')
    BEGIN
        DECLARE @blockers NVARCHAR(1000) = (
            SELECT LEFT(STRING_AGG(CONCAT(c.CiName, N' (', t.type_name, N')'), N', '), 900)
              FROM grac_practice.fn_asset_relationship_blockers(@organization_id, N'ASSET', @asset_id) b
              JOIN grac_practice.asset_relationship_type t ON t.type_code = b.TypeCode
              LEFT JOIN grac_practice.fn_asset_ci_catalog(@organization_id) c ON c.CiKind = b.DependentKind AND c.CiId = b.DependentId);
        IF @blockers IS NOT NULL
        BEGIN
            DECLARE @blk_msg NVARCHAR(1400) = CONCAT(N'Active critical dependencies still rely on this asset: ', @blockers,
                N'. Reassign or retire them, or accept them for retirement (Asset Relationships), first.');
            THROW 54719, @blk_msg, 1;
        END
    END

    DECLARE @log_id BIGINT;
    BEGIN TRAN;
    IF @req_approval = 1
    BEGIN
        INSERT grac_practice.asset_lifecycle_change
            (organization_id, asset_id, transition_rule_id, from_status_code, to_status_code, change_status,
             reason_text, reference_text, evidence_text, requested_by, requested_by_employee_id)
        VALUES (@organization_id, @asset_id, @rule_id, @from, @to_status_code, N'PENDING_APPROVAL',
                @reason_text, @reference_text, @evidence_text, @actor, @actor_employee_id);
        SET @out_change_id = SCOPE_IDENTITY();
        SET @out_result = N'PENDING_APPROVAL';
    END
    ELSE
    BEGIN
        EXEC grac_practice.sp_asset_lifecycle_apply
             @organization_id = @organization_id, @asset_id = @asset_id,
             @from_status_code = @from, @to_status_code = @to_status_code,
             @reason_code = N'LIFECYCLE', @reason_text = @reason_text,
             @actor_employee_id = @actor_employee_id, @actor = @actor, @out_log_id = @log_id OUTPUT;
        INSERT grac_practice.asset_lifecycle_change
            (organization_id, asset_id, transition_rule_id, from_status_code, to_status_code, change_status,
             reason_text, reference_text, evidence_text, requested_by, requested_by_employee_id, transition_log_id)
        VALUES (@organization_id, @asset_id, @rule_id, @from, @to_status_code, N'COMPLETED',
                @reason_text, @reference_text, @evidence_text, @actor, @actor_employee_id, @log_id);
        SET @out_change_id = SCOPE_IDENTITY();
        SET @out_result = N'COMPLETED';
    END
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-lifecycle', @asset_id, CASE WHEN @req_approval = 1 THEN N'REQUEST' ELSE N'TRANSITION' END,
            (SELECT @from AS statusCode FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            (SELECT @out_change_id AS changeId, @to_status_code AS toStatusCode, @out_result AS result,
                    @reason_text AS reason, @reference_text AS reference, @evidence_text AS evidence, @log_id AS transitionLogId
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            N'Active', @actor);
    COMMIT;

    SELECT @out_change_id AS ChangeId, @out_result AS Result,
           CASE WHEN @out_result = N'COMPLETED' THEN @to_status_code ELSE @from END AS StatusCode;
END
GO
PRINT '440: sp_asset_lifecycle_transition re-issued.';
GO

-- =====================================================================
-- 8. Menu: Asset & Contract -> Asset Relationships (also carried in 274)
-- =====================================================================
MERGE grac_practice.menu_master AS t
USING (VALUES
    (N'asset-relationships', N'Asset Relationships', N'Practice/Index/asset-relationships', 361, N'diagram-project', N'Asset & Contract')
) AS s(menu_key, menu_name, menu_url, display_order, icon_class, module_type)
ON t.menu_key = s.menu_key
WHEN MATCHED AND (ISNULL(t.menu_name, N'') <> s.menu_name OR ISNULL(t.menu_url, N'') <> s.menu_url
               OR t.display_order <> s.display_order OR ISNULL(t.icon_class, N'') <> s.icon_class
               OR ISNULL(t.module_type, N'') <> s.module_type OR t.status <> N'Active') THEN UPDATE SET
    menu_name = s.menu_name, menu_url = s.menu_url, display_order = s.display_order, icon_class = s.icon_class,
    module_type = s.module_type, status = N'Active', updated_by = N'seed-440', updated_dt = SYSUTCDATETIME()
WHEN NOT MATCHED BY TARGET THEN
    INSERT (menu_key, menu_name, menu_url, display_order, icon_class, module_type, status, entered_by)
    VALUES (s.menu_key, s.menu_name, s.menu_url, s.display_order, s.icon_class, s.module_type, N'Active', N'seed-440');
PRINT CONCAT('440: menu row upserted: ', @@ROWCOUNT);
GO

UPDATE c
   SET parent_menu_id = p.menu_id, updated_by = N'seed-440', updated_dt = SYSUTCDATETIME()
  FROM grac_practice.menu_master c
  JOIN grac_practice.menu_master p ON p.menu_key = N'nav-asset-contract'
 WHERE c.menu_key = N'asset-relationships' AND ISNULL(c.parent_menu_id, -1) <> p.menu_id;
GO

DECLARE @active_rs INT = (
    SELECT TOP 1 record_status_id FROM grac_practice.record_status_master
     WHERE status_code = N'Active' OR status_name = N'Active' ORDER BY record_status_id);
IF @active_rs IS NULL SET @active_rs = 1;
INSERT grac_practice.organization_role_menu_permission
    (role_id, menu_id, can_view, can_add, can_edit, can_delete, can_approve, status, record_status_id, entered_by, entered_dt)
SELECT r.role_id, m.menu_id, 1, 1, 1, 0, 1, N'Active', @active_rs, N'seed-440', SYSUTCDATETIME()
  FROM grac_practice.organization_role r
  JOIN grac_practice.menu_master m ON m.menu_key = N'asset-relationships'
 WHERE r.role_name = N'Admin' AND r.status = N'Active'
   AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_role_menu_permission e
                    WHERE e.role_id = r.role_id AND e.menu_id = m.menu_id);
PRINT CONCAT('440: Admin grants inserted: ', @@ROWCOUNT);
GO

-- =====================================================================
-- Verification
-- =====================================================================
SELECT '440-a relationship types (12, Supports Service inactive until 7.2)' AS Check_,
       CASE WHEN (SELECT COUNT(*) FROM grac_practice.asset_relationship_type) >= 12
             AND EXISTS (SELECT 1 FROM grac_practice.asset_relationship_type WHERE type_code = N'SUPPORTS_SERVICE' AND is_active = 0)
             AND EXISTS (SELECT 1 FROM grac_practice.asset_relationship_type
                          WHERE type_code = N'HOSTED_ON' AND cardinality = N'ONE_TARGET' AND loop_rule = N'BLOCK' AND dependent_side = N'SOURCE')
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '440-b relationship and history tables, current-relationship index',
       CASE WHEN OBJECT_ID('grac_practice.asset_relationship','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.asset_relationship_history','U') IS NOT NULL
             AND EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ux_pm_asset_rel_current' AND is_unique = 1)
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '440-c functions and procedures present',
       CASE WHEN OBJECT_ID('grac_practice.fn_asset_ci_catalog') IS NOT NULL
             AND OBJECT_ID('grac_practice.fn_asset_relationship_edges') IS NOT NULL
             AND OBJECT_ID('grac_practice.fn_asset_relationship_blockers') IS NOT NULL
             AND (SELECT COUNT(*) FROM sys.procedures WHERE SCHEMA_NAME(schema_id) = 'grac_practice'
                   AND name IN ('sp_asset_relationship_check', 'sp_asset_relationship_history_add', 'sp_asset_relationship_sync',
                                'sp_asset_relationship_save', 'sp_asset_relationship_action', 'sp_asset_ci_impact',
                                'sp_asset_relationship_config_get', 'sp_asset_ci_lookup', 'sp_asset_relationships',
                                'sp_asset_relationship_get')) = 10
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '440-d lifecycle transition carries the 435 coverage gate and the 440 retirement gate',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_asset_lifecycle_transition')) LIKE '%THROW 54560%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_asset_lifecycle_transition')) LIKE '%THROW 54719%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '440-e menu row Active under Asset & Contract',
       CASE WHEN EXISTS (SELECT 1 FROM grac_practice.menu_master c
                           JOIN grac_practice.menu_master p ON p.menu_id = c.parent_menu_id AND p.menu_key = N'nav-asset-contract'
                          WHERE c.menu_key = N'asset-relationships' AND c.status = N'Active') THEN 'PASS' ELSE 'FAIL' END;
GO

-- =====================================================================
-- UAT (after deploying the API + Web build; re-login for the menu grant)
--   Needs: users P (proposes) and A (approves), both with
--   asset-relationships; application APP1; server assets SRV1 and SRV2;
--   a database asset DB1.
--   1. Asset Relationships -> Add: APP1 "Runs on" SRV1 -> Proposed. A
--      approves -> Active (Verified).
--   2. Add DB1 "Is hosted on" SRV1, then DB1 "Is hosted on" SRV2 -> refused
--      (one target only, 54707). Add APP1 "Depends on" DB1, critical, High;
--      P cannot approve it (54716); A approves.
--   3. Add DB1 "Depends on" APP1 -> refused: circular dependency (54708).
--   4. Impact analysis: SRV1, downstream -> DB1 (level 1), APP1 (level 1,
--      runs on SRV1) -- APP1 listed once although it is also reached through
--      DB1. Upstream from APP1 -> SRV1 and DB1. Critical only -> DB1 only.
--   5. Open APP1 depends on DB1 (critical): change the weight with a reason
--      -> pending approval, still Active; A approves -> version 2 in history.
--      Retire it -> pending; reject it with a note.
--   6. Asset Register -> DB1 -> Lifecycle: move towards disposal
--      (Pending Decommission -> Sanitization) -> refused, naming APP1
--      (54719). Accept the dependency for retirement (A, note) -> allowed.
--   7. Set an effective-to date in the past on a non-critical relationship
--      -> the list shows it Inactive; it stays in the history.
-- =====================================================================
