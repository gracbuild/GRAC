-- =====================================================================
-- 442  Asset discovery and reconciliation: source profiles, field
--      precedence, identification rules, observations, matching outcomes,
--      reconciliation queue, data confidence and freshness
--      (Asset & Contract Management, Phase 7 increment 3)
--
-- REQUEST
-- -------
--   BRD v1.7 5.6 "Asset Discovery and Reconciliation": ingest asset
--   observations from approved discovery, endpoint, identity, cloud,
--   network, security, ERP and specialist systems and reconcile them to
--   governed asset records without silently overwriting approved data.
--   5.6.1 source profile (ID / name, type, authoritative domains, schedule /
--   mode, tenant / scope, field mapping version, source priority by field,
--   health / last run, owner / credential reference, retention); 5.6.2
--   identification and matching (cloud resource ID, serial + make / model,
--   asset tag / finance asset ID, device / directory ID, hostname + domain,
--   MAC, IP as a low-confidence signal; composite rules, normalization,
--   strong identifiers above mutable ones; a score from matched
--   attributes, conflicts and source trust; thresholds for Auto Match,
--   Suggested Match, Manual Review, New Candidate, Conflict); 5.6.3
--   outcomes (create candidate, update existing by precedence, no change,
--   conflict with both values kept plus exception and owner task,
--   potential duplicate review); 5.6.4 confidence and freshness (identity,
--   attribute, freshness, conflict, verification; Verified / Probable /
--   Unverified / Stale / Conflicting); 5.6.5 acceptance criteria (idempotent
--   repeats, identical rules for UI / import / API, traceability to the
--   observation and rule version, low-confidence changes never overwrite,
--   per-record results for partial batches). Plan:
--   docs/asset-contract-management.md (Phase 7.3, D97-D107).
--
-- WHAT THIS DOES
-- --------------
--   1. Discovery sources (per organization) with field precedence (golden /
--      contributing source per field and priority), trust, expected
--      observation interval, retention and health.
--   2. Identification rules (per organization, defaults seeded on first
--      use) and reconciliation settings (score thresholds, stale multiplier,
--      verification window, conflict tasks) with a rule-set version.
--   3. Ingestion (sp_asset_discovery_ingest): one batch per source and
--      batch reference (a repeated reference returns the first batch); each
--      record reconciled on its own (a failed record never undoes the
--      others); per-record results; retention applied to the source.
--   4. Reconciliation of an observation: an unchanged repeat is No change;
--      otherwise every active rule is scored against the register and the
--      source links; Auto Match updates the asset by field precedence,
--      Suggested / Manual review / New candidate / Potential duplicate open
--      a reconciliation exception; a value the source may not overwrite is a
--      Conflict exception (both values kept) with an owner task.
--   5. Reconciliation queue: link (apply), ignore, not a duplicate, accept
--      the observed value or keep the current one.
--   6. Data confidence per asset (fn_asset_discovery_confidence): identity
--      score, freshness, open conflicts, verification -> Verified / Probable
--      / Unverified / Stale / Conflicting.
--   7. Asset Discovery screen (menu row, readers / writers); Task Centre
--      task type Asset Reconciliation.
--
-- NOT DONE HERE: merge and split of assets, stale-asset retirement with
--   source confirmation (Phase 7.4); connectors that pull from external
--   systems (batches are posted by import or API); creating a register asset
--   from a new candidate (register it, then link the candidate); updating
--   make / model / lookup fields from observations (recorded only);
--   relationship observations.
--
-- ERROR NUMBERS: 54760-54779
--   54760 organization not found          54761 source not found
--   54762 source code / name              54763 source type / mode
--   54764 trust / interval / retention    54765 owner
--   54766 field precedence                54767 rule not found
--   54768 rule definition                 54769 thresholds
--   54770 source inactive                 54771 batch reference / records
--   54772 too many records                54773 exception not found
--   54774 changed by someone else         54775 exception not open
--   54776 action not valid                54777 asset
--   54778 note required                   54779 batch not found
--
-- ALSO EDITED: API (AssetConfig service / controller / models), Web proxy,
--   PracticeScreen + Manage.cshtml + appsettings, asset-discovery.cshtml /
--   .js (new), 274 (menu), docs.
-- DEPENDS ON: 196, 420, 425, 428, 438.
-- Rollback: 442_asset_discovery_rollback.sql
-- Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.sp_asset_field_value_set','P') IS NULL
   OR OBJECT_ID('grac_practice.asset_make','U') IS NULL
   OR OBJECT_ID('grac_practice.asset_model','U') IS NULL
   OR OBJECT_ID('grac_practice.sp_task_open','P') IS NULL
   OR NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_practice_task_source_type' AND definition LIKE '%Asset''%')
BEGIN
    RAISERROR('ABORT (442): run 196, 420, 425, 428 and 438 first.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. Task type for conflict tasks
-- =====================================================================
MERGE grac_practice.task_type_master AS t
USING (VALUES (N'AssetReconciliation', N'Asset Reconciliation', N'Resolve a discovery conflict on an asset record', 72, N'Medium', 1, 91))
   AS s(type_code, type_name, description, default_sla_hours, default_priority, is_system_only, display_order)
ON t.type_code = s.type_code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (type_code, type_name, description, default_sla_hours, default_priority, is_system_only, display_order, entered_by)
    VALUES (s.type_code, s.type_name, s.description, s.default_sla_hours, s.default_priority, s.is_system_only, s.display_order, N'seed-442');
PRINT CONCAT('442: task type inserted: ', @@ROWCOUNT);
GO

-- =====================================================================
-- 2. Sources and field precedence (5.6.1)
-- =====================================================================
IF OBJECT_ID('grac_practice.asset_discovery_source','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_discovery_source (
        source_id                  BIGINT         IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_adisc_src PRIMARY KEY,
        organization_id            BIGINT         NOT NULL
            CONSTRAINT fk_pm_adisc_src_org REFERENCES grac_practice.organization(organization_id),
        source_code                NVARCHAR(40)   NOT NULL,
        source_name                NVARCHAR(200)  NOT NULL,
        source_type                NVARCHAR(12)   NOT NULL
            CONSTRAINT ck_pm_adisc_src_type CHECK (source_type IN (N'DISCOVERY', N'ENDPOINT', N'IDENTITY', N'CLOUD', N'NETWORK', N'SECURITY',
                                                                   N'ERP', N'BIOMEDICAL', N'FLEET', N'CUSTOM')),
        collection_mode            NVARCHAR(8)    NOT NULL
            CONSTRAINT ck_pm_adisc_src_mode CHECK (collection_mode IN (N'POLLING', N'WEBHOOK', N'BATCH', N'FILE', N'API')),
        scope_text                 NVARCHAR(400)  NULL,     -- accounts, subscriptions, sites, networks
        mapping_version            NVARCHAR(40)   NULL,     -- approved field mapping version
        owner_employee_id          BIGINT         NULL
            CONSTRAINT fk_pm_adisc_src_owner REFERENCES grac_practice.organization_employee(employee_id),
        credential_reference       NVARCHAR(200)  NULL,     -- a vault reference, never a secret
        trust_level                INT            NOT NULL CONSTRAINT ck_pm_adisc_src_trust CHECK (trust_level BETWEEN 1 AND 100),
        expected_interval_hours    INT            NOT NULL CONSTRAINT ck_pm_adisc_src_int CHECK (expected_interval_hours BETWEEN 1 AND 8760),
        raw_retention_days         INT            NOT NULL CONSTRAINT ck_pm_adisc_src_raw CHECK (raw_retention_days BETWEEN 1 AND 3650),
        observation_retention_days INT            NOT NULL CONSTRAINT ck_pm_adisc_src_obs CHECK (observation_retention_days BETWEEN 1 AND 3650),
        is_active                  BIT            NOT NULL,
        last_batch_id              BIGINT         NULL,
        last_run_dt                DATETIME2      NULL,
        last_run_status            NVARCHAR(10)   NULL,
        entered_by                 NVARCHAR(100)  NOT NULL CONSTRAINT df_pm_adisc_src_eby DEFAULT N'system',
        entered_dt                 DATETIME2      NOT NULL CONSTRAINT df_pm_adisc_src_edt DEFAULT SYSUTCDATETIME(),
        updated_by                 NVARCHAR(100)  NULL,
        updated_dt                 DATETIME2      NULL,
        record_version             ROWVERSION     NOT NULL,
        CONSTRAINT uq_pm_adisc_src_code UNIQUE (organization_id, source_code),
        CONSTRAINT uq_pm_adisc_src_name UNIQUE (organization_id, source_name)
    );
    PRINT '442: asset_discovery_source created.';
END
GO

IF OBJECT_ID('grac_practice.asset_discovery_priority','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_discovery_priority (
        source_id   BIGINT        NOT NULL
            CONSTRAINT fk_pm_adisc_pri_src REFERENCES grac_practice.asset_discovery_source(source_id),
        field_key   NVARCHAR(100) NOT NULL,
        source_role NVARCHAR(12)  NOT NULL
            CONSTRAINT ck_pm_adisc_pri_role CHECK (source_role IN (N'GOLDEN', N'CONTRIBUTING', N'IGNORED')),
        priority    INT           NOT NULL CONSTRAINT ck_pm_adisc_pri_pri CHECK (priority BETWEEN 1 AND 999),
        CONSTRAINT pk_pm_adisc_pri PRIMARY KEY (source_id, field_key)
    );
    PRINT '442: asset_discovery_priority created.';
END
GO

-- =====================================================================
-- 3. Identification rules and settings (5.6.2)
-- =====================================================================
IF OBJECT_ID('grac_practice.asset_identification_rule','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_identification_rule (
        rule_id         BIGINT        IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_aid_rule PRIMARY KEY,
        organization_id BIGINT        NOT NULL
            CONSTRAINT fk_pm_aid_rule_org REFERENCES grac_practice.organization(organization_id),
        rule_name       NVARCHAR(120) NOT NULL,
        attribute_keys  NVARCHAR(400) NOT NULL,     -- comma list of field keys; @source_key = the record ID at the source
        strength        NVARCHAR(10)  NOT NULL
            CONSTRAINT ck_pm_aid_rule_str CHECK (strength IN (N'STRONG', N'SUPPORTING', N'WEAK')),
        weight          INT           NOT NULL CONSTRAINT ck_pm_aid_rule_w CHECK (weight BETWEEN 1 AND 100),
        is_active       BIT           NOT NULL,
        display_order   INT           NOT NULL,
        entered_by      NVARCHAR(100) NOT NULL CONSTRAINT df_pm_aid_rule_eby DEFAULT N'system',
        entered_dt      DATETIME2     NOT NULL CONSTRAINT df_pm_aid_rule_edt DEFAULT SYSUTCDATETIME(),
        updated_by      NVARCHAR(100) NULL,
        updated_dt      DATETIME2     NULL,
        CONSTRAINT uq_pm_aid_rule_name UNIQUE (organization_id, rule_name)
    );
    PRINT '442: asset_identification_rule created.';
END
GO

IF OBJECT_ID('grac_practice.asset_discovery_setting','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_discovery_setting (
        organization_id       BIGINT        NOT NULL CONSTRAINT pk_pm_adisc_set PRIMARY KEY
            CONSTRAINT fk_pm_adisc_set_org REFERENCES grac_practice.organization(organization_id),
        auto_match_score      INT           NOT NULL,
        suggested_score       INT           NOT NULL,
        manual_review_score   INT           NOT NULL,
        stale_multiplier      INT           NOT NULL CONSTRAINT ck_pm_adisc_set_stale CHECK (stale_multiplier BETWEEN 1 AND 100),
        verification_days     INT           NOT NULL CONSTRAINT ck_pm_adisc_set_ver CHECK (verification_days BETWEEN 1 AND 3650),
        create_conflict_tasks BIT           NOT NULL,
        rule_set_version      INT           NOT NULL,
        updated_by            NVARCHAR(100) NOT NULL,
        updated_dt            DATETIME2     NOT NULL CONSTRAINT df_pm_adisc_set_udt DEFAULT SYSUTCDATETIME(),
        CONSTRAINT ck_pm_adisc_set_thr CHECK (auto_match_score <= 100 AND auto_match_score > suggested_score
                                              AND suggested_score > manual_review_score AND manual_review_score >= 1)
    );
    PRINT '442: asset_discovery_setting created.';
END
GO

-- =====================================================================
-- 4. Batches, observations, links, attribute sources (5.6.3-5.6.5)
-- =====================================================================
IF OBJECT_ID('grac_practice.asset_discovery_batch','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_discovery_batch (
        batch_id         BIGINT        IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_adisc_batch PRIMARY KEY,
        organization_id  BIGINT        NOT NULL,
        source_id        BIGINT        NOT NULL
            CONSTRAINT fk_pm_adisc_batch_src REFERENCES grac_practice.asset_discovery_source(source_id),
        batch_reference  NVARCHAR(100) NOT NULL,
        channel          NVARCHAR(10)  NOT NULL CONSTRAINT ck_pm_adisc_batch_ch CHECK (channel IN (N'UI', N'IMPORT', N'API')),
        status           NVARCHAR(10)  NOT NULL
            CONSTRAINT ck_pm_adisc_batch_status CHECK (status IN (N'RUNNING', N'COMPLETED', N'PARTIAL', N'FAILED')),
        record_count     INT           NOT NULL CONSTRAINT df_pm_adisc_batch_rc DEFAULT 0,
        updated_count    INT           NOT NULL CONSTRAINT df_pm_adisc_batch_uc DEFAULT 0,
        no_change_count  INT           NOT NULL CONSTRAINT df_pm_adisc_batch_nc DEFAULT 0,
        exception_count  INT           NOT NULL CONSTRAINT df_pm_adisc_batch_xc DEFAULT 0,
        error_count      INT           NOT NULL CONSTRAINT df_pm_adisc_batch_ec DEFAULT 0,
        rule_set_version INT           NOT NULL,
        received_dt      DATETIME2     NOT NULL CONSTRAINT df_pm_adisc_batch_rdt DEFAULT SYSUTCDATETIME(),
        completed_dt     DATETIME2     NULL,
        entered_by       NVARCHAR(100) NOT NULL,
        CONSTRAINT uq_pm_adisc_batch_ref UNIQUE (source_id, batch_reference)
    );
    PRINT '442: asset_discovery_batch created.';
END
GO

IF OBJECT_ID('grac_practice.asset_discovery_observation','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_discovery_observation (
        observation_id   BIGINT         IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_adisc_obs PRIMARY KEY,
        organization_id  BIGINT         NOT NULL,
        batch_id         BIGINT         NOT NULL
            CONSTRAINT fk_pm_adisc_obs_batch REFERENCES grac_practice.asset_discovery_batch(batch_id),
        source_id        BIGINT         NOT NULL,
        record_no        INT            NOT NULL,
        external_key     NVARCHAR(200)  NULL,
        observed_dt      DATETIME2      NOT NULL,
        payload_json     NVARCHAR(MAX)  NULL,      -- normalized attributes; cleared after the raw retention
        payload_hash     VARBINARY(32)  NULL,
        outcome          NVARCHAR(20)   NULL
            CONSTRAINT ck_pm_adisc_obs_outcome CHECK (outcome IS NULL OR outcome IN (N'UPDATED', N'NO_CHANGE', N'SUGGESTED', N'MANUAL_REVIEW',
                                                                                    N'NEW_CANDIDATE', N'POTENTIAL_DUPLICATE', N'ERROR')),
        match_score      INT            NULL,
        matched_asset_id BIGINT         NULL,
        second_asset_id  BIGINT         NULL,
        second_score     INT            NULL,
        matched_rules    NVARCHAR(400)  NULL,
        result_text      NVARCHAR(1000) NULL,
        rule_set_version INT            NOT NULL,
        entered_dt       DATETIME2      NOT NULL CONSTRAINT df_pm_adisc_obs_edt DEFAULT SYSUTCDATETIME()
    );
    CREATE INDEX ix_pm_adisc_obs_batch ON grac_practice.asset_discovery_observation(batch_id, record_no);
    CREATE INDEX ix_pm_adisc_obs_key ON grac_practice.asset_discovery_observation(source_id, external_key);
    PRINT '442: asset_discovery_observation created.';
END
GO

IF OBJECT_ID('grac_practice.asset_discovery_link','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_discovery_link (
        link_id             BIGINT        IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_adisc_link PRIMARY KEY,
        organization_id     BIGINT        NOT NULL,
        asset_id            BIGINT        NOT NULL
            CONSTRAINT fk_pm_adisc_link_asset REFERENCES grac_practice.organization_dependency_asset(asset_id),
        source_id           BIGINT        NOT NULL
            CONSTRAINT fk_pm_adisc_link_src REFERENCES grac_practice.asset_discovery_source(source_id),
        external_key        NVARCHAR(200) NOT NULL,
        identity_score      INT           NOT NULL,
        link_method         NVARCHAR(10)  NOT NULL CONSTRAINT ck_pm_adisc_link_m CHECK (link_method IN (N'AUTO', N'CONFIRMED')),
        first_seen_dt       DATETIME2     NOT NULL,
        last_seen_dt        DATETIME2     NOT NULL,
        last_observation_id BIGINT        NULL,
        last_payload_hash   VARBINARY(32) NULL,
        CONSTRAINT uq_pm_adisc_link_key UNIQUE (source_id, external_key)
    );
    CREATE INDEX ix_pm_adisc_link_asset ON grac_practice.asset_discovery_link(asset_id);
    PRINT '442: asset_discovery_link created.';
END
GO

IF OBJECT_ID('grac_practice.asset_attribute_source','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_attribute_source (
        asset_id       BIGINT        NOT NULL
            CONSTRAINT fk_pm_aattr_src_asset REFERENCES grac_practice.organization_dependency_asset(asset_id),
        field_key      NVARCHAR(100) NOT NULL,
        source_id      BIGINT        NOT NULL
            CONSTRAINT fk_pm_aattr_src_src REFERENCES grac_practice.asset_discovery_source(source_id),
        observed_value NVARCHAR(400) NULL,
        observed_dt    DATETIME2     NOT NULL,
        observation_id BIGINT        NOT NULL,
        applied        BIT           NOT NULL,
        CONSTRAINT pk_pm_aattr_src PRIMARY KEY (asset_id, field_key, source_id)
    );
    PRINT '442: asset_attribute_source created.';
END
GO

IF OBJECT_ID('grac_practice.asset_reconciliation_exception','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_reconciliation_exception (
        exception_id     BIGINT         IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_arec_exc PRIMARY KEY,
        organization_id  BIGINT         NOT NULL,
        exception_kind   NVARCHAR(16)   NOT NULL
            CONSTRAINT ck_pm_arec_exc_kind CHECK (exception_kind IN (N'SUGGESTED_MATCH', N'MANUAL_REVIEW', N'NEW_CANDIDATE', N'DUPLICATE', N'CONFLICT')),
        observation_id   BIGINT         NOT NULL
            CONSTRAINT fk_pm_arec_exc_obs REFERENCES grac_practice.asset_discovery_observation(observation_id),
        source_id        BIGINT         NOT NULL,
        external_key     NVARCHAR(200)  NULL,
        asset_id         BIGINT         NULL,
        other_asset_id   BIGINT         NULL,
        field_key        NVARCHAR(100)  NULL,
        current_value    NVARCHAR(400)  NULL,
        observed_value   NVARCHAR(400)  NULL,
        match_score      INT            NULL,
        status           NVARCHAR(10)   NOT NULL CONSTRAINT ck_pm_arec_exc_status CHECK (status IN (N'OPEN', N'RESOLVED')),
        resolution       NVARCHAR(20)   NULL,
        resolution_note  NVARCHAR(1000) NULL,
        resolved_by      NVARCHAR(100)  NULL,
        resolved_dt      DATETIME2      NULL,
        task_id          BIGINT         NULL,
        raised_count     INT            NOT NULL CONSTRAINT df_pm_arec_exc_rc DEFAULT 1,
        entered_dt       DATETIME2      NOT NULL CONSTRAINT df_pm_arec_exc_edt DEFAULT SYSUTCDATETIME(),
        updated_dt       DATETIME2      NULL,
        record_version   ROWVERSION     NOT NULL
    );
    CREATE INDEX ix_pm_arec_exc_org ON grac_practice.asset_reconciliation_exception(organization_id, status, exception_kind);
    CREATE INDEX ix_pm_arec_exc_key ON grac_practice.asset_reconciliation_exception(source_id, external_key, status);
    PRINT '442: asset_reconciliation_exception created.';
END
GO

IF OBJECT_ID('grac_practice.asset_duplicate_decision','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_duplicate_decision (
        asset_id_low  BIGINT         NOT NULL,
        asset_id_high BIGINT         NOT NULL,
        note          NVARCHAR(1000) NOT NULL,
        decided_by    NVARCHAR(100)  NOT NULL,
        decided_dt    DATETIME2      NOT NULL CONSTRAINT df_pm_adup_dt DEFAULT SYSUTCDATETIME(),
        CONSTRAINT pk_pm_adup PRIMARY KEY (asset_id_low, asset_id_high)
    );
    PRINT '442: asset_duplicate_decision created.';
END
GO

-- =====================================================================
-- 5. Helpers, defaults, configuration writers
-- =====================================================================
-- Normalized identity value: trimmed upper case; a MAC loses its
-- separators; a hostname is compared by its short name (D99).
CREATE OR ALTER FUNCTION grac_practice.fn_asset_norm (@field_key NVARCHAR(100), @value NVARCHAR(400))
RETURNS NVARCHAR(400)
AS
BEGIN
    DECLARE @v NVARCHAR(400) = UPPER(LTRIM(RTRIM(ISNULL(@value, N''))));
    IF @field_key = N'mac_address' SET @v = REPLACE(REPLACE(REPLACE(@v, N':', N''), N'-', N''), N'.', N'');
    IF @field_key = N'hostname' AND CHARINDEX(N'.', @v) > 1 SET @v = LEFT(@v, CHARINDEX(N'.', @v) - 1);
    RETURN NULLIF(@v, N'');
END
GO

-- Default identification rules and settings of an organization (BRD 5.6.2
-- table; D98-D99). Only adds what is missing.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_discovery_defaults_ensure
    @organization_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.asset_discovery_setting WHERE organization_id = @organization_id)
        INSERT grac_practice.asset_discovery_setting
            (organization_id, auto_match_score, suggested_score, manual_review_score, stale_multiplier, verification_days,
             create_conflict_tasks, rule_set_version, updated_by)
        VALUES (@organization_id, 90, 70, 40, 3, 365, 1, 1, N'seed-442');
    IF NOT EXISTS (SELECT 1 FROM grac_practice.asset_identification_rule WHERE organization_id = @organization_id)
        INSERT grac_practice.asset_identification_rule
            (organization_id, rule_name, attribute_keys, strength, weight, is_active, display_order, entered_by)
        SELECT @organization_id, r.rule_name, r.attribute_keys, r.strength, r.weight, 1, r.display_order, N'seed-442'
          FROM (VALUES (N'Cloud resource identifier', N'cloud_resource_identifier', N'STRONG', 100, 10),
                       (N'Serial number + make + model', N'serial_number,manufacturer_make,model', N'STRONG', 95, 20),
                       (N'Source record ID (device / directory ID)', N'@source_key', N'STRONG', 95, 30),
                       (N'Asset tag', N'asset_tag', N'STRONG', 90, 40),
                       (N'Finance asset number', N'finance_asset_number', N'STRONG', 85, 50),
                       (N'Serial number', N'serial_number', N'SUPPORTING', 75, 60),
                       (N'Hostname + domain', N'hostname,domain', N'SUPPORTING', 70, 70),
                       (N'MAC address', N'mac_address', N'SUPPORTING', 65, 80),
                       (N'Hostname', N'hostname', N'SUPPORTING', 50, 90),
                       (N'IP address', N'ip_address', N'WEAK', 25, 100)) AS r(rule_name, attribute_keys, strength, weight, display_order);
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_asset_discovery_source_save
    @organization_id            BIGINT,
    @source_id                  BIGINT        = NULL,
    @source_code                NVARCHAR(40)  = NULL,
    @source_name                NVARCHAR(200) = NULL,
    @source_type                NVARCHAR(12)  = NULL,
    @collection_mode            NVARCHAR(8)   = NULL,
    @scope_text                 NVARCHAR(400) = NULL,
    @mapping_version            NVARCHAR(40)  = NULL,
    @owner_employee_id          BIGINT        = NULL,
    @credential_reference       NVARCHAR(200) = NULL,
    @trust_level                INT           = 80,
    @expected_interval_hours    INT           = 24,
    @raw_retention_days         INT           = 30,
    @observation_retention_days INT           = 365,
    @is_active                  BIT           = 1,
    @expected_record_version    BIGINT        = NULL,
    @actor                      NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    SET @source_code = NULLIF(UPPER(LTRIM(RTRIM(@source_code))), N'');
    SET @source_name = NULLIF(LTRIM(RTRIM(@source_name)), N'');
    SET @source_type = UPPER(LTRIM(RTRIM(ISNULL(@source_type, N''))));
    SET @collection_mode = UPPER(LTRIM(RTRIM(ISNULL(@collection_mode, N''))));
    SET @scope_text = NULLIF(LTRIM(RTRIM(@scope_text)), N'');
    SET @mapping_version = NULLIF(LTRIM(RTRIM(@mapping_version)), N'');
    SET @credential_reference = NULLIF(LTRIM(RTRIM(@credential_reference)), N'');
    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 54760, 'Organization not found.', 1;
    IF @source_code IS NULL OR @source_name IS NULL
        THROW 54762, 'Enter the source ID and name.', 1;
    IF EXISTS (SELECT 1 FROM grac_practice.asset_discovery_source
                WHERE organization_id = @organization_id AND source_id <> ISNULL(@source_id, -1)
                  AND (source_code = @source_code OR source_name = @source_name))
        THROW 54762, 'Another source already uses this source ID or name.', 1;
    IF @source_type NOT IN (N'DISCOVERY', N'ENDPOINT', N'IDENTITY', N'CLOUD', N'NETWORK', N'SECURITY', N'ERP', N'BIOMEDICAL', N'FLEET', N'CUSTOM')
       OR @collection_mode NOT IN (N'POLLING', N'WEBHOOK', N'BATCH', N'FILE', N'API')
        THROW 54763, 'Select the source type and the collection mode.', 1;
    IF ISNULL(@trust_level, 0) NOT BETWEEN 1 AND 100 OR ISNULL(@expected_interval_hours, 0) NOT BETWEEN 1 AND 8760
       OR ISNULL(@raw_retention_days, 0) NOT BETWEEN 1 AND 3650 OR ISNULL(@observation_retention_days, 0) NOT BETWEEN 1 AND 3650
       OR @raw_retention_days > @observation_retention_days
        THROW 54764, 'Trust 1-100, expected interval 1-8760 hours, retention 1-3650 days (raw payloads no longer than observations).', 1;
    IF @owner_employee_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee
            WHERE employee_id = @owner_employee_id AND organization_id = @organization_id AND status = N'Active')
        THROW 54765, 'The source owner must be an active employee of the organization.', 1;
    DECLARE @id BIGINT = @source_id, @before NVARCHAR(MAX);
    IF @source_id IS NOT NULL
    BEGIN
        DECLARE @rv BIGINT;
        SELECT @rv = CONVERT(BIGINT, record_version),
               @before = (SELECT s2.source_code AS sourceCode, s2.source_name AS sourceName, s2.trust_level AS trustLevel,
                                 s2.is_active AS isActive FROM grac_practice.asset_discovery_source s2
                           WHERE s2.source_id = @source_id FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)
          FROM grac_practice.asset_discovery_source WHERE source_id = @source_id AND organization_id = @organization_id;
        IF @rv IS NULL THROW 54761, 'Discovery source not found for this organization.', 1;
        IF @expected_record_version IS NOT NULL AND @expected_record_version <> @rv
            THROW 54774, 'The source was changed by someone else; reload it and try again.', 1;
    END
    BEGIN TRAN;
    IF @id IS NULL
    BEGIN
        INSERT grac_practice.asset_discovery_source
            (organization_id, source_code, source_name, source_type, collection_mode, scope_text, mapping_version, owner_employee_id,
             credential_reference, trust_level, expected_interval_hours, raw_retention_days, observation_retention_days, is_active, entered_by)
        VALUES (@organization_id, @source_code, @source_name, @source_type, @collection_mode, @scope_text, @mapping_version,
                @owner_employee_id, @credential_reference, @trust_level, @expected_interval_hours, @raw_retention_days,
                @observation_retention_days, ISNULL(@is_active, 1), @actor);
        SET @id = SCOPE_IDENTITY();
    END
    ELSE
        UPDATE grac_practice.asset_discovery_source
           SET source_code = @source_code, source_name = @source_name, source_type = @source_type, collection_mode = @collection_mode,
               scope_text = @scope_text, mapping_version = @mapping_version, owner_employee_id = @owner_employee_id,
               credential_reference = @credential_reference, trust_level = @trust_level, expected_interval_hours = @expected_interval_hours,
               raw_retention_days = @raw_retention_days, observation_retention_days = @observation_retention_days,
               is_active = ISNULL(@is_active, 1), updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE source_id = @id;
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-discovery-source', @id, CASE WHEN @source_id IS NULL THEN N'CREATE' ELSE N'UPDATE' END, @before,
            (SELECT @source_code AS sourceCode, @source_name AS sourceName, @source_type AS sourceType, @collection_mode AS collectionMode,
                    @trust_level AS trustLevel, @expected_interval_hours AS expectedIntervalHours, ISNULL(@is_active, 1) AS isActive
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            N'Active', @actor);
    COMMIT;
    SELECT @id AS SourceId, CASE WHEN @source_id IS NULL THEN N'CREATED' ELSE N'SAVED' END AS Result;
END
GO

-- Field precedence of a source (replaces the list):
-- [{"fieldKey":"hostname","sourceRole":"GOLDEN","priority":1}, ...]. One
-- golden source per field in the organization (D100).
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_discovery_priorities_save
    @organization_id BIGINT,
    @source_id       BIGINT,
    @priorities_json NVARCHAR(MAX),
    @actor           NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    IF NOT EXISTS (SELECT 1 FROM grac_practice.asset_discovery_source WHERE source_id = @source_id AND organization_id = @organization_id)
        THROW 54761, 'Discovery source not found for this organization.', 1;
    IF ISJSON(ISNULL(@priorities_json, N'')) = 0 THROW 54766, 'The field precedence list is not valid.', 1;
    DECLARE @p TABLE (field_key NVARCHAR(100) NOT NULL PRIMARY KEY, source_role NVARCHAR(12) NOT NULL, priority INT NOT NULL);
    INSERT @p (field_key, source_role, priority)
    SELECT LTRIM(RTRIM(j.fieldKey)), UPPER(LTRIM(RTRIM(ISNULL(j.sourceRole, N'CONTRIBUTING')))), ISNULL(j.priority, 100)
      FROM OPENJSON(@priorities_json) WITH (fieldKey NVARCHAR(100), sourceRole NVARCHAR(12), priority INT) j
     WHERE NULLIF(LTRIM(RTRIM(j.fieldKey)), N'') IS NOT NULL;
    IF EXISTS (SELECT 1 FROM @p p WHERE p.source_role NOT IN (N'GOLDEN', N'CONTRIBUTING', N'IGNORED') OR p.priority NOT BETWEEN 1 AND 999
                  OR NOT EXISTS (SELECT 1 FROM grac_practice.asset_field_definition f WHERE f.field_key = p.field_key))
        THROW 54766, 'Each entry names a dictionary field, a role (golden, contributing, ignored) and a priority 1-999.', 1;
    DECLARE @clash NVARCHAR(400) = (
        SELECT TOP 1 CONCAT(p.field_key, N' (', s.source_name, N')')
          FROM @p p
          JOIN grac_practice.asset_discovery_priority o ON o.field_key = p.field_key AND o.source_role = N'GOLDEN' AND o.source_id <> @source_id
          JOIN grac_practice.asset_discovery_source s ON s.source_id = o.source_id AND s.organization_id = @organization_id
         WHERE p.source_role = N'GOLDEN');
    IF @clash IS NOT NULL
    BEGIN
        DECLARE @msg NVARCHAR(600) = CONCAT(N'Another source is already the golden source of ', @clash, N'.');
        THROW 54766, @msg, 1;
    END
    BEGIN TRAN;
    DELETE FROM grac_practice.asset_discovery_priority WHERE source_id = @source_id;
    INSERT grac_practice.asset_discovery_priority (source_id, field_key, source_role, priority)
    SELECT @source_id, field_key, source_role, priority FROM @p;
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-discovery-source', @source_id, N'PRECEDENCE', NULL, @priorities_json, N'Active', @actor);
    COMMIT;
    SELECT @source_id AS SourceId, N'SAVED' AS Result;
END
GO

-- Identification rule (new or changed). Attribute keys are dictionary
-- fields or @source_key. Every change bumps the rule-set version.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_identification_rule_save
    @organization_id BIGINT,
    @rule_id         BIGINT        = NULL,
    @rule_name       NVARCHAR(120) = NULL,
    @attribute_keys  NVARCHAR(400) = NULL,
    @strength        NVARCHAR(10)  = NULL,
    @weight          INT           = NULL,
    @is_active       BIT           = 1,
    @display_order   INT           = 100,
    @actor           NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    SET @rule_name = NULLIF(LTRIM(RTRIM(@rule_name)), N'');
    SET @attribute_keys = NULLIF(LOWER(REPLACE(LTRIM(RTRIM(@attribute_keys)), N' ', N'')), N'');
    SET @strength = UPPER(LTRIM(RTRIM(ISNULL(@strength, N''))));
    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 54760, 'Organization not found.', 1;
    EXEC grac_practice.sp_asset_discovery_defaults_ensure @organization_id = @organization_id;
    IF @rule_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.asset_identification_rule
                                             WHERE rule_id = @rule_id AND organization_id = @organization_id)
        THROW 54767, 'Identification rule not found for this organization.', 1;
    IF @rule_name IS NULL OR @attribute_keys IS NULL OR @strength NOT IN (N'STRONG', N'SUPPORTING', N'WEAK')
       OR ISNULL(@weight, 0) NOT BETWEEN 1 AND 100
       OR EXISTS (SELECT 1 FROM STRING_SPLIT(@attribute_keys, N',') x
                   WHERE x.value <> N'@source_key'
                     AND NOT EXISTS (SELECT 1 FROM grac_practice.asset_field_definition f WHERE f.field_key = x.value))
       OR EXISTS (SELECT 1 FROM grac_practice.asset_identification_rule
                   WHERE organization_id = @organization_id AND rule_name = @rule_name AND rule_id <> ISNULL(@rule_id, -1))
        THROW 54768, 'Name the rule (unique), list dictionary field keys (or @source_key), choose the strength and a weight 1-100.', 1;
    DECLARE @id BIGINT = @rule_id;
    BEGIN TRAN;
    IF @id IS NULL
    BEGIN
        INSERT grac_practice.asset_identification_rule
            (organization_id, rule_name, attribute_keys, strength, weight, is_active, display_order, entered_by)
        VALUES (@organization_id, @rule_name, @attribute_keys, @strength, @weight, ISNULL(@is_active, 1), ISNULL(@display_order, 100), @actor);
        SET @id = SCOPE_IDENTITY();
    END
    ELSE
        UPDATE grac_practice.asset_identification_rule
           SET rule_name = @rule_name, attribute_keys = @attribute_keys, strength = @strength, weight = @weight,
               is_active = ISNULL(@is_active, 1), display_order = ISNULL(@display_order, 100), updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE rule_id = @id;
    UPDATE grac_practice.asset_discovery_setting
       SET rule_set_version = rule_set_version + 1, updated_by = @actor, updated_dt = SYSUTCDATETIME()
     WHERE organization_id = @organization_id;
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-identification-rule', @id, CASE WHEN @rule_id IS NULL THEN N'CREATE' ELSE N'UPDATE' END, NULL,
            (SELECT @rule_name AS ruleName, @attribute_keys AS attributeKeys, @strength AS strength, @weight AS weight,
                    ISNULL(@is_active, 1) AS isActive FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            N'Active', @actor);
    COMMIT;
    SELECT @id AS RuleId, CASE WHEN @rule_id IS NULL THEN N'CREATED' ELSE N'SAVED' END AS Result;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_asset_discovery_setting_save
    @organization_id       BIGINT,
    @auto_match_score      INT,
    @suggested_score       INT,
    @manual_review_score   INT,
    @stale_multiplier      INT,
    @verification_days     INT,
    @create_conflict_tasks BIT,
    @actor                 NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 54760, 'Organization not found.', 1;
    IF ISNULL(@auto_match_score, 0) > 100 OR ISNULL(@auto_match_score, 0) <= ISNULL(@suggested_score, 0)
       OR ISNULL(@suggested_score, 0) <= ISNULL(@manual_review_score, 0) OR ISNULL(@manual_review_score, 0) < 1
       OR ISNULL(@stale_multiplier, 0) NOT BETWEEN 1 AND 100 OR ISNULL(@verification_days, 0) NOT BETWEEN 1 AND 3650
        THROW 54769, 'Thresholds: auto match (up to 100) above suggested above manual review (at least 1); stale multiplier 1-100; verification 1-3650 days.', 1;
    EXEC grac_practice.sp_asset_discovery_defaults_ensure @organization_id = @organization_id;
    BEGIN TRAN;
    UPDATE grac_practice.asset_discovery_setting
       SET auto_match_score = @auto_match_score, suggested_score = @suggested_score, manual_review_score = @manual_review_score,
           stale_multiplier = @stale_multiplier, verification_days = @verification_days,
           create_conflict_tasks = ISNULL(@create_conflict_tasks, 1), rule_set_version = rule_set_version + 1,
           updated_by = @actor, updated_dt = SYSUTCDATETIME()
     WHERE organization_id = @organization_id;
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-discovery-setting', @organization_id, N'UPDATE', NULL,
            (SELECT @auto_match_score AS autoMatchScore, @suggested_score AS suggestedScore, @manual_review_score AS manualReviewScore,
                    @stale_multiplier AS staleMultiplier, @verification_days AS verificationDays,
                    ISNULL(@create_conflict_tasks, 1) AS createConflictTasks FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            N'Active', @actor);
    COMMIT;
    SELECT @organization_id AS OrganizationId, N'SAVED' AS Result;
END
GO
PRINT '442: helpers and configuration writers created.';
GO

-- =====================================================================
-- 6. Reconciliation engine (5.6.2-5.6.5; D99-D104)
-- =====================================================================
-- Fills the caller-created #iv (asset_id, field_key, norm) with the
-- normalized identity values of the organization (or one asset) for the
-- fields the active rules use (#ra), plus the record IDs this source
-- already linked (@source_key). Disposed / archived assets are not matched.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_discovery_identity_load
    @organization_id BIGINT,
    @source_id       BIGINT,
    @asset_id        BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DELETE FROM #iv WHERE @asset_id IS NULL OR asset_id = @asset_id;
    INSERT #iv (asset_id, field_key, norm)
    SELECT v.asset_id, f.field_key, n.norm
      FROM grac_practice.asset_field_value v
      JOIN grac_practice.asset_field_definition f ON f.field_definition_id = v.field_definition_id
      JOIN grac_practice.organization_dependency_asset a ON a.asset_id = v.asset_id AND a.organization_id = @organization_id
      LEFT JOIN grac_practice.entity_status_master s ON s.entity_status_id = a.current_status_id
      LEFT JOIN grac_practice.asset_make mk ON f.data_type_code = N'MAKE' AND mk.make_id = v.value_ref
      LEFT JOIN grac_practice.asset_model md ON f.data_type_code = N'MODEL' AND md.model_id = v.value_ref
     CROSS APPLY (SELECT grac_practice.fn_asset_norm(f.field_key,
                         CASE f.data_type_code WHEN N'MAKE' THEN mk.make_name WHEN N'MODEL' THEN md.model_name
                                               ELSE v.value_text END) AS norm) n
     WHERE (@asset_id IS NULL OR v.asset_id = @asset_id)
       AND ISNULL(s.status_code, N'ACTIVE') NOT IN (N'DISPOSED', N'ARCHIVED')
       AND n.norm IS NOT NULL
       AND f.field_key IN (SELECT field_key FROM #ra)
    UNION ALL
    SELECT l.asset_id, N'@source_key', UPPER(l.external_key)
      FROM grac_practice.asset_discovery_link l
     WHERE l.source_id = @source_id AND (@asset_id IS NULL OR l.asset_id = @asset_id);
END
GO

-- Opens (or refreshes) a reconciliation exception: one open exception per
-- source record, kind and field (repeats are counted, not duplicated). A
-- new Conflict opens an owner task when the settings ask for it (D102).
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_reconciliation_exception_raise
    @organization_id BIGINT,
    @exception_kind  NVARCHAR(16),
    @observation_id  BIGINT,
    @source_id       BIGINT,
    @external_key    NVARCHAR(200) = NULL,
    @asset_id        BIGINT        = NULL,
    @other_asset_id  BIGINT        = NULL,
    @field_key       NVARCHAR(100) = NULL,
    @current_value   NVARCHAR(400) = NULL,
    @observed_value  NVARCHAR(400) = NULL,
    @match_score     INT           = NULL,
    @actor           NVARCHAR(100) = N'discovery'
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @eid BIGINT = (SELECT TOP 1 exception_id FROM grac_practice.asset_reconciliation_exception
                            WHERE source_id = @source_id AND exception_kind = @exception_kind AND status = N'OPEN'
                              AND ISNULL(field_key, N'') = ISNULL(@field_key, N'')
                              AND ((@external_key IS NOT NULL AND external_key = @external_key)
                                   OR (@external_key IS NULL AND observation_id = @observation_id))
                            ORDER BY exception_id);
    IF @eid IS NOT NULL
    BEGIN
        UPDATE grac_practice.asset_reconciliation_exception
           SET observation_id = @observation_id, asset_id = @asset_id, other_asset_id = @other_asset_id, current_value = @current_value,
               observed_value = @observed_value, match_score = @match_score, raised_count = raised_count + 1, updated_dt = SYSUTCDATETIME()
         WHERE exception_id = @eid;
        RETURN;
    END
    INSERT grac_practice.asset_reconciliation_exception
        (organization_id, exception_kind, observation_id, source_id, external_key, asset_id, other_asset_id, field_key, current_value,
         observed_value, match_score, status)
    VALUES (@organization_id, @exception_kind, @observation_id, @source_id, @external_key, @asset_id, @other_asset_id, @field_key,
            @current_value, @observed_value, @match_score, N'OPEN');
    SET @eid = SCOPE_IDENTITY();
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-reconciliation-exception', @eid, N'RAISE', NULL,
            (SELECT @exception_kind AS kind, @observation_id AS observationId, @asset_id AS assetId, @other_asset_id AS otherAssetId,
                    @field_key AS fieldKey, @current_value AS currentValue, @observed_value AS observedValue, @match_score AS matchScore
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            N'Active', @actor);

    IF @exception_kind = N'CONFLICT' AND @asset_id IS NOT NULL
       AND EXISTS (SELECT 1 FROM grac_practice.asset_discovery_setting WHERE organization_id = @organization_id AND create_conflict_tasks = 1)
    BEGIN
        DECLARE @owner BIGINT, @asset_name NVARCHAR(400), @crit NVARCHAR(40), @prio NVARCHAR(30), @title NVARCHAR(250),
                @descr NVARCHAR(MAX), @ref NVARCHAR(200), @tid BIGINT, @src_name NVARCHAR(200);
        SELECT @owner = grac_practice.fn_asset_activity_person(@organization_id, CAST(a.owner_id AS NVARCHAR(30))),
               @asset_name = a.asset_name, @crit = c.criticality_code
          FROM grac_practice.organization_dependency_asset a
          LEFT JOIN grac_practice.criticality_master c ON c.criticality_id = a.criticality_id
         WHERE a.asset_id = @asset_id;
        SET @src_name = (SELECT source_name FROM grac_practice.asset_discovery_source WHERE source_id = @source_id);
        SET @prio = CASE @crit WHEN N'Critical' THEN N'Critical' WHEN N'High' THEN N'High' WHEN N'Low' THEN N'Low' ELSE N'Medium' END;
        SET @title = LEFT(CONCAT(N'Discovery conflict - ', @asset_name, N' (', @field_key, N')'), 250);
        SET @descr = CONCAT(N'Source ', @src_name, N' reports ', @field_key, N' = "', @observed_value, N'"; the register holds "',
                            @current_value, N'". Both values are kept; resolve it in Asset Discovery (reconciliation exception ', @eid, N').');
        SET @ref = CONCAT(N'REC-', @eid);
        EXEC grac_practice.sp_task_open
             @organization_id         = @organization_id,
             @task_type_code          = N'AssetReconciliation',
             @subject_entity_type     = N'AssetReconciliationException',
             @subject_entity_id       = @eid,
             @subject_title           = @title,
             @subject_description     = @descr,
             @priority                = @prio,
             @criticality             = @crit,
             @origin_code             = N'GRAC',
             @assigned_to_employee_id = @owner,
             @target_date             = NULL,
             @source_type_code        = N'Asset',
             @source_record_id        = @eid,
             @source_reference        = @ref,
             @resolve_owner           = 0,
             @task_id                 = @tid OUTPUT;
        UPDATE grac_practice.asset_reconciliation_exception SET task_id = @tid WHERE exception_id = @eid;
    END
END
GO

-- Applies an observation to an asset (Auto Match or a confirmed link):
-- links the source record, records every attribute per source and writes
-- the fields the source may change (D100-D101):
--   ignored by the source precedence     recorded only
--   same value                           nothing
--   not a writable value field           recorded only (make, model, lookups, people...)
--   empty on the asset                   filled (golden or contributing)
--   different, golden source             overwritten
--   different, otherwise                 Conflict exception (both values kept)
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_discovery_apply
    @observation_id    BIGINT,
    @asset_id          BIGINT,
    @link_method       NVARCHAR(10)  = N'AUTO',
    @match_score       INT           = NULL,
    @actor             NVARCHAR(100) = N'discovery',
    @out_updated       INT           = NULL OUTPUT,
    @out_conflicts     INT           = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SELECT @out_updated = 0, @out_conflicts = 0;
    DECLARE @org BIGINT, @source BIGINT, @key NVARCHAR(200), @payload NVARCHAR(MAX), @hash VARBINARY(32), @seen DATETIME2;
    SELECT @org = organization_id, @source = source_id, @key = external_key, @payload = payload_json, @hash = payload_hash,
           @seen = observed_dt
      FROM grac_practice.asset_discovery_observation WHERE observation_id = @observation_id;

    IF @key IS NOT NULL
        MERGE grac_practice.asset_discovery_link AS t
        USING (SELECT @source AS source_id, @key AS external_key) AS s ON t.source_id = s.source_id AND t.external_key = s.external_key
        WHEN MATCHED THEN UPDATE SET asset_id = @asset_id, identity_score = ISNULL(@match_score, t.identity_score), link_method = @link_method,
            last_seen_dt = CASE WHEN @seen > t.last_seen_dt THEN @seen ELSE t.last_seen_dt END, last_observation_id = @observation_id,
            last_payload_hash = @hash
        WHEN NOT MATCHED THEN INSERT (organization_id, asset_id, source_id, external_key, identity_score, link_method, first_seen_dt,
                                      last_seen_dt, last_observation_id, last_payload_hash)
            VALUES (@org, @asset_id, @source, @key, ISNULL(@match_score, 100), @link_method, @seen, @seen, @observation_id, @hash);

    DECLARE @fk NVARCHAR(100), @obs NVARCHAR(400), @dtype NVARCHAR(30), @storage NVARCHAR(10), @role NVARCHAR(12), @cur NVARCHAR(400),
            @applied BIT, @changed NVARCHAR(MAX) = NULL;
    DECLARE fld_cur CURSOR LOCAL STATIC FOR
        SELECT f.field_key, LEFT(CAST(j.[value] AS NVARCHAR(MAX)), 400), f.data_type_code, f.storage_kind, ISNULL(p.source_role, N'CONTRIBUTING')
          FROM OPENJSON(@payload) j
          -- OPENJSON keys are Latin1_General_BIN2: compare in the database collation (Msg 468)
          JOIN grac_practice.asset_field_definition f ON f.field_key = j.[key] COLLATE DATABASE_DEFAULT
          LEFT JOIN grac_practice.asset_discovery_priority p ON p.source_id = @source AND p.field_key = f.field_key
         WHERE j.[type] IN (1, 2) AND NULLIF(LTRIM(RTRIM(CAST(j.[value] AS NVARCHAR(MAX)))), N'') IS NOT NULL;
    OPEN fld_cur;
    FETCH NEXT FROM fld_cur INTO @fk, @obs, @dtype, @storage, @role;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @obs = LTRIM(RTRIM(@obs));
        SET @cur = (SELECT v.value_text FROM grac_practice.asset_field_value v
                      JOIN grac_practice.asset_field_definition f ON f.field_definition_id = v.field_definition_id AND f.field_key = @fk
                     WHERE v.asset_id = @asset_id);
        SET @applied = 0;
        IF @role <> N'IGNORED' AND ISNULL(grac_practice.fn_asset_norm(@fk, @cur), N'') = ISNULL(grac_practice.fn_asset_norm(@fk, @obs), N'')
        BEGIN
            SET @applied = 1;
        END
        ELSE IF @role <> N'IGNORED' AND @storage = N'VALUE'
                AND @dtype IN (N'TEXT', N'MULTILINE', N'DECIMAL', N'PERCENT', N'QUANTITY_UNIT', N'DATE', N'IP_ADDRESS', N'IP_LIST')
        BEGIN
            IF @cur IS NULL OR @role = N'GOLDEN'
            BEGIN
                EXEC grac_practice.sp_asset_field_value_set @asset_id = @asset_id, @field_key = @fk, @value = @obs, @actor = @actor;
                SET @applied = 1;
                SET @out_updated = @out_updated + 1;
                SET @changed = CONCAT(@changed, CASE WHEN @changed IS NULL THEN N'' ELSE N', ' END, @fk);
            END
            ELSE
            BEGIN
                EXEC grac_practice.sp_asset_reconciliation_exception_raise
                     @organization_id = @org, @exception_kind = N'CONFLICT', @observation_id = @observation_id, @source_id = @source,
                     @external_key = @key, @asset_id = @asset_id, @field_key = @fk, @current_value = @cur, @observed_value = @obs,
                     @match_score = @match_score, @actor = @actor;
                SET @out_conflicts = @out_conflicts + 1;
            END
        END
        MERGE grac_practice.asset_attribute_source AS t
        USING (SELECT @asset_id AS asset_id, @fk AS field_key, @source AS source_id) AS s
           ON t.asset_id = s.asset_id AND t.field_key = s.field_key AND t.source_id = s.source_id
        WHEN MATCHED THEN UPDATE SET observed_value = @obs, observed_dt = @seen, observation_id = @observation_id, applied = @applied
        WHEN NOT MATCHED THEN INSERT (asset_id, field_key, source_id, observed_value, observed_dt, observation_id, applied)
            VALUES (@asset_id, @fk, @source, @obs, @seen, @observation_id, @applied);
        FETCH NEXT FROM fld_cur INTO @fk, @obs, @dtype, @storage, @role;
    END
    CLOSE fld_cur;
    DEALLOCATE fld_cur;

    IF @out_updated > 0
        INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
        VALUES (N'asset-register', @asset_id, N'DISCOVERY', NULL,
                (SELECT @observation_id AS observationId, @source AS sourceId, @key AS externalKey, @changed AS fields
                    FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
                N'Active', @actor);
    IF OBJECT_ID('tempdb..#iv') IS NOT NULL
        EXEC grac_practice.sp_asset_discovery_identity_load @organization_id = @org, @source_id = @source, @asset_id = @asset_id;
END
GO

-- Reconciles one observation. Needs #iv, #irule, #ra and #strong from the
-- caller (sp_asset_discovery_ingest). Score of an asset (D99): the best
-- matched rule weight, +5 for each further matched rule, -30 for each
-- strong identifier both sides hold with different values, bounded 0-100
-- and scaled by the source trust. Outcomes (D101): repeat of the linked
-- record -> No change; two assets at or above the suggested score (not
-- decided as distinct) -> Potential duplicate; best at or above auto match
-- -> applied; at or above suggested -> Suggested; at or above manual review
-- -> Manual review; else New candidate.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_discovery_reconcile
    @observation_id BIGINT,
    @actor          NVARCHAR(100) = N'discovery'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @org BIGINT, @source BIGINT, @key NVARCHAR(200), @payload NVARCHAR(MAX), @hash VARBINARY(32), @seen DATETIME2, @trust INT,
            @auto INT, @sug INT, @man INT;
    SELECT @org = o.organization_id, @source = o.source_id, @key = o.external_key, @payload = o.payload_json, @hash = o.payload_hash,
           @seen = o.observed_dt, @trust = s.trust_level
      FROM grac_practice.asset_discovery_observation o
      JOIN grac_practice.asset_discovery_source s ON s.source_id = o.source_id
     WHERE o.observation_id = @observation_id;
    SELECT @auto = auto_match_score, @sug = suggested_score, @man = manual_review_score
      FROM grac_practice.asset_discovery_setting WHERE organization_id = @org;

    -- Repeat of a linked record with the same content: freshness only (5.6.5).
    DECLARE @link_asset BIGINT, @link_hash VARBINARY(32);
    SELECT @link_asset = asset_id, @link_hash = last_payload_hash
      FROM grac_practice.asset_discovery_link WHERE source_id = @source AND external_key = @key;
    IF @link_asset IS NOT NULL AND @link_hash = @hash
    BEGIN
        UPDATE grac_practice.asset_discovery_link
           SET last_seen_dt = CASE WHEN @seen > last_seen_dt THEN @seen ELSE last_seen_dt END, last_observation_id = @observation_id
         WHERE source_id = @source AND external_key = @key;
        UPDATE grac_practice.asset_discovery_observation
           SET outcome = N'NO_CHANGE', matched_asset_id = @link_asset, result_text = N'Same content as the last observation of this record.'
         WHERE observation_id = @observation_id;
        RETURN;
    END

    CREATE TABLE #attr (field_key NVARCHAR(100) COLLATE DATABASE_DEFAULT NOT NULL PRIMARY KEY, norm NVARCHAR(400) COLLATE DATABASE_DEFAULT NOT NULL);
    INSERT #attr (field_key, norm)
    SELECT j.[key] COLLATE DATABASE_DEFAULT, MIN(n.norm)
      FROM OPENJSON(@payload) j
     CROSS APPLY (SELECT grac_practice.fn_asset_norm(j.[key], LEFT(CAST(j.[value] AS NVARCHAR(MAX)), 400)) AS norm) n
     WHERE j.[type] IN (1, 2) AND n.norm IS NOT NULL
     GROUP BY j.[key] COLLATE DATABASE_DEFAULT;
    IF @key IS NOT NULL AND NOT EXISTS (SELECT 1 FROM #attr WHERE field_key = N'@source_key')
        INSERT #attr (field_key, norm) VALUES (N'@source_key', UPPER(@key));

    CREATE TABLE #m (asset_id BIGINT NOT NULL, rule_id BIGINT NOT NULL);
    INSERT #m (asset_id, rule_id)
    SELECT iv.asset_id, ra.rule_id
      FROM #ra ra
      JOIN #attr a ON a.field_key = ra.field_key
      JOIN #iv iv ON iv.field_key = ra.field_key AND iv.norm = a.norm
     GROUP BY iv.asset_id, ra.rule_id, ra.n
    HAVING COUNT(DISTINCT ra.field_key) = ra.n;

    CREATE TABLE #s (asset_id BIGINT NOT NULL PRIMARY KEY, base INT NOT NULL, nrules INT NOT NULL, rules NVARCHAR(400) COLLATE DATABASE_DEFAULT NULL,
                     penalty INT NOT NULL, raw_score INT NULL, score INT NULL);
    INSERT #s (asset_id, base, nrules, rules, penalty)
    SELECT m.asset_id, MAX(r.weight), COUNT(*), LEFT(STRING_AGG(r.rule_name, N', '), 400), 0
      FROM #m m JOIN #irule r ON r.rule_id = m.rule_id
     GROUP BY m.asset_id;
    UPDATE s
       SET penalty = (SELECT COUNT(*) FROM #iv iv
                        JOIN #attr a ON a.field_key = iv.field_key
                        JOIN #strong st ON st.field_key = iv.field_key
                       WHERE iv.asset_id = s.asset_id AND iv.norm <> a.norm)
      FROM #s s;
    UPDATE #s SET raw_score = base + 5 * (nrules - 1) - 30 * penalty;
    UPDATE #s SET score = CAST(ROUND((CASE WHEN raw_score > 100 THEN 100 WHEN raw_score < 0 THEN 0 ELSE raw_score END) * @trust / 100.0, 0) AS INT);

    DECLARE @best BIGINT, @best_score INT, @best_rules NVARCHAR(400), @second BIGINT, @second_score INT;
    SELECT TOP 1 @best = asset_id, @best_score = score, @best_rules = rules FROM #s ORDER BY score DESC, asset_id;
    SELECT TOP 1 @second = asset_id, @second_score = score FROM #s WHERE asset_id <> ISNULL(@best, -1) ORDER BY score DESC, asset_id;
    DECLARE @distinct BIT = CASE WHEN EXISTS (SELECT 1 FROM grac_practice.asset_duplicate_decision
                                               WHERE asset_id_low = CASE WHEN @best < @second THEN @best ELSE @second END
                                                 AND asset_id_high = CASE WHEN @best < @second THEN @second ELSE @best END)
                                 THEN 1 ELSE 0 END;
    DECLARE @outcome NVARCHAR(20), @text NVARCHAR(1000), @upd INT, @conf INT;
    IF @second IS NOT NULL AND @second_score >= @sug AND @distinct = 0
    BEGIN
        EXEC grac_practice.sp_asset_reconciliation_exception_raise
             @organization_id = @org, @exception_kind = N'DUPLICATE', @observation_id = @observation_id, @source_id = @source,
             @external_key = @key, @asset_id = @best, @other_asset_id = @second, @match_score = @best_score, @actor = @actor;
        SELECT @outcome = N'POTENTIAL_DUPLICATE',
               @text = CONCAT(N'Two register assets match (scores ', @best_score, N' and ', @second_score, N'); duplicate review opened.');
    END
    ELSE IF @best_score >= @auto
    BEGIN
        EXEC grac_practice.sp_asset_discovery_apply @observation_id = @observation_id, @asset_id = @best, @link_method = N'AUTO',
             @match_score = @best_score, @actor = @actor, @out_updated = @upd OUTPUT, @out_conflicts = @conf OUTPUT;
        SELECT @outcome = CASE WHEN @upd > 0 THEN N'UPDATED' ELSE N'NO_CHANGE' END,
               @text = CONCAT(N'Auto match (', @best_rules, N'): ', @upd, N' field(s) updated, ', @conf, N' conflict(s).');
    END
    ELSE IF @best_score >= @sug
    BEGIN
        EXEC grac_practice.sp_asset_reconciliation_exception_raise
             @organization_id = @org, @exception_kind = N'SUGGESTED_MATCH', @observation_id = @observation_id, @source_id = @source,
             @external_key = @key, @asset_id = @best, @match_score = @best_score, @actor = @actor;
        SELECT @outcome = N'SUGGESTED', @text = CONCAT(N'Suggested match (', @best_rules, N'); confirm the link.');
    END
    ELSE IF @best_score >= @man
    BEGIN
        EXEC grac_practice.sp_asset_reconciliation_exception_raise
             @organization_id = @org, @exception_kind = N'MANUAL_REVIEW', @observation_id = @observation_id, @source_id = @source,
             @external_key = @key, @asset_id = @best, @match_score = @best_score, @actor = @actor;
        SELECT @outcome = N'MANUAL_REVIEW', @text = CONCAT(N'Low-confidence match (', @best_rules, N'); review it.');
    END
    ELSE
    BEGIN
        EXEC grac_practice.sp_asset_reconciliation_exception_raise
             @organization_id = @org, @exception_kind = N'NEW_CANDIDATE', @observation_id = @observation_id, @source_id = @source,
             @external_key = @key, @asset_id = @best, @match_score = @best_score, @actor = @actor;
        SELECT @outcome = N'NEW_CANDIDATE', @text = N'No register asset matches; staged as a new candidate.';
    END
    UPDATE grac_practice.asset_discovery_observation
       SET outcome = @outcome, match_score = @best_score, matched_asset_id = @best, second_asset_id = @second, second_score = @second_score,
           matched_rules = @best_rules, result_text = @text
     WHERE observation_id = @observation_id;
END
GO

-- Ingests a batch from a source (UI, import or API -- identical rules):
--   @records_json = [{"externalKey":"...","observedAt":"2026-10-05T10:00:00Z",
--                     "attributes":{"serial_number":"...","hostname":"..."}}, ...]
-- observedAt is ISO 8601; an offset (or Z) is converted to UTC, no offset
-- is taken as UTC, a missing or invalid value is the receipt time.
-- A repeated batch reference returns the earlier batch (IsRepeat = 1)
-- without processing it again. Up to 5000 records; each record is reconciled in its own
-- transaction and keeps its own result (D103). Retention of the source is
-- applied afterwards. 1. batch  2. records.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_discovery_ingest
    @organization_id   BIGINT,
    @source_id         BIGINT,
    @batch_reference   NVARCHAR(100),
    @channel           NVARCHAR(10)  = N'UI',
    @records_json      NVARCHAR(MAX) = NULL,
    @actor_employee_id BIGINT        = NULL,
    @actor             NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT OFF;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    SET @batch_reference = NULLIF(LTRIM(RTRIM(@batch_reference)), N'');
    SET @channel = CASE UPPER(ISNULL(@channel, N'')) WHEN N'IMPORT' THEN N'IMPORT' WHEN N'API' THEN N'API' ELSE N'UI' END;
    DECLARE @active BIT, @raw_days INT, @obs_days INT;
    SELECT @active = is_active, @raw_days = raw_retention_days, @obs_days = observation_retention_days
      FROM grac_practice.asset_discovery_source WHERE source_id = @source_id AND organization_id = @organization_id;
    IF @active IS NULL THROW 54761, 'Discovery source not found for this organization.', 1;
    IF @active = 0 THROW 54770, 'The discovery source is inactive.', 1;
    DECLARE @existing BIGINT = (SELECT batch_id FROM grac_practice.asset_discovery_batch
                                 WHERE source_id = @source_id AND batch_reference = @batch_reference);
    DECLARE @repeat BIT = CASE WHEN @existing IS NULL THEN 0 ELSE 1 END;
    IF @existing IS NULL
    BEGIN
        IF @batch_reference IS NULL OR ISJSON(ISNULL(@records_json, N'')) = 0 OR LEFT(LTRIM(@records_json), 1) <> N'['
            THROW 54771, 'Give a batch reference and the records as a JSON array.', 1;
        IF (SELECT COUNT(*) FROM OPENJSON(@records_json)) > 5000
            THROW 54772, 'A batch holds at most 5000 records; split it.', 1;
        EXEC grac_practice.sp_asset_discovery_defaults_ensure @organization_id = @organization_id;
        DECLARE @version INT = (SELECT rule_set_version FROM grac_practice.asset_discovery_setting WHERE organization_id = @organization_id);
        INSERT grac_practice.asset_discovery_batch (organization_id, source_id, batch_reference, channel, status, rule_set_version, entered_by)
        VALUES (@organization_id, @source_id, @batch_reference, @channel, N'RUNNING', @version, @actor);
        DECLARE @batch BIGINT = SCOPE_IDENTITY();

        INSERT grac_practice.asset_discovery_observation
            (organization_id, batch_id, source_id, record_no, external_key, observed_dt, payload_json, payload_hash, outcome, result_text,
             rule_set_version)
        SELECT @organization_id, @batch, @source_id, CAST(j.[key] AS INT) + 1, r.k, ISNULL(r.observed_at, SYSUTCDATETIME()),
               CASE WHEN ISJSON(r.attributes) = 1 AND LEFT(LTRIM(r.attributes), 1) = N'{' THEN r.attributes END,
               HASHBYTES('SHA2_256', CONCAT(r.k, N'|', r.attributes)),
               CASE WHEN ISJSON(r.attributes) = 1 AND LEFT(LTRIM(r.attributes), 1) = N'{' THEN NULL ELSE N'ERROR' END,
               CASE WHEN ISJSON(r.attributes) = 1 AND LEFT(LTRIM(r.attributes), 1) = N'{' THEN NULL
                    ELSE N'The record has no attributes object.' END,
               @version
          FROM OPENJSON(@records_json) j
         CROSS APPLY (SELECT NULLIF(LTRIM(RTRIM(x.externalKey)), N'') AS k, CONVERT(DATETIME2, SWITCHOFFSET(TRY_CONVERT(DATETIMEOFFSET, x.observedAt), N'+00:00')) AS observed_at,
                             x.attributes
                        FROM OPENJSON(j.[value]) WITH (externalKey NVARCHAR(200), observedAt NVARCHAR(40),
                                                       attributes NVARCHAR(MAX) AS JSON) x) r
         WHERE j.[type] = 5;

        CREATE TABLE #irule (rule_id BIGINT NOT NULL PRIMARY KEY, rule_name NVARCHAR(120) COLLATE DATABASE_DEFAULT NOT NULL, weight INT NOT NULL,
                             strength NVARCHAR(10) COLLATE DATABASE_DEFAULT NOT NULL);
        CREATE TABLE #ra (rule_id BIGINT NOT NULL, field_key NVARCHAR(100) COLLATE DATABASE_DEFAULT NOT NULL, n INT NOT NULL);
        CREATE TABLE #strong (field_key NVARCHAR(100) COLLATE DATABASE_DEFAULT NOT NULL PRIMARY KEY);
        CREATE TABLE #iv (asset_id BIGINT NOT NULL, field_key NVARCHAR(100) COLLATE DATABASE_DEFAULT NOT NULL,
                          norm NVARCHAR(400) COLLATE DATABASE_DEFAULT NOT NULL);
        CREATE INDEX ix_iv ON #iv (field_key, norm) INCLUDE (asset_id);
        INSERT #irule (rule_id, rule_name, weight, strength)
        SELECT rule_id, rule_name, weight, strength FROM grac_practice.asset_identification_rule
         WHERE organization_id = @organization_id AND is_active = 1;
        INSERT #ra (rule_id, field_key, n)
        SELECT r.rule_id, LTRIM(RTRIM(x.value)), COUNT(*) OVER (PARTITION BY r.rule_id)
          FROM grac_practice.asset_identification_rule r
         CROSS APPLY (SELECT DISTINCT value FROM STRING_SPLIT(r.attribute_keys, N',') WHERE LTRIM(RTRIM(value)) <> N'') x
         WHERE r.organization_id = @organization_id AND r.is_active = 1;
        INSERT #strong (field_key)
        SELECT DISTINCT ra.field_key FROM #ra ra JOIN #irule r ON r.rule_id = ra.rule_id
         WHERE r.strength = N'STRONG' AND ra.field_key <> N'@source_key';
        EXEC grac_practice.sp_asset_discovery_identity_load @organization_id = @organization_id, @source_id = @source_id;

        DECLARE @obs BIGINT, @err NVARCHAR(1000);
        DECLARE rec_cur CURSOR LOCAL STATIC FOR
            SELECT observation_id FROM grac_practice.asset_discovery_observation WHERE batch_id = @batch AND outcome IS NULL ORDER BY record_no;
        OPEN rec_cur;
        FETCH NEXT FROM rec_cur INTO @obs;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            BEGIN TRY
                BEGIN TRAN;
                EXEC grac_practice.sp_asset_discovery_reconcile @observation_id = @obs, @actor = @actor;
                COMMIT;
            END TRY
            BEGIN CATCH
                IF XACT_STATE() <> 0 ROLLBACK;
                SET @err = LEFT(ERROR_MESSAGE(), 1000);
                UPDATE grac_practice.asset_discovery_observation SET outcome = N'ERROR', result_text = @err WHERE observation_id = @obs;
                -- the identity values may have changed inside the rolled-back record
                EXEC grac_practice.sp_asset_discovery_identity_load @organization_id = @organization_id, @source_id = @source_id;
            END CATCH
            FETCH NEXT FROM rec_cur INTO @obs;
        END
        CLOSE rec_cur;
        DEALLOCATE rec_cur;

        UPDATE b
           SET record_count = x.total, updated_count = x.upd, no_change_count = x.same, exception_count = x.exc, error_count = x.err,
               status = CASE WHEN x.total > 0 AND x.err = x.total THEN N'FAILED' WHEN x.err > 0 THEN N'PARTIAL' ELSE N'COMPLETED' END,
               completed_dt = SYSUTCDATETIME()
          FROM grac_practice.asset_discovery_batch b
         CROSS APPLY (SELECT COUNT(*) AS total,
                             ISNULL(SUM(CASE WHEN outcome = N'UPDATED' THEN 1 ELSE 0 END), 0) AS upd,
                             ISNULL(SUM(CASE WHEN outcome = N'NO_CHANGE' THEN 1 ELSE 0 END), 0) AS same,
                             ISNULL(SUM(CASE WHEN outcome IN (N'SUGGESTED', N'MANUAL_REVIEW', N'NEW_CANDIDATE', N'POTENTIAL_DUPLICATE')
                                             THEN 1 ELSE 0 END), 0) AS exc,
                             ISNULL(SUM(CASE WHEN outcome = N'ERROR' THEN 1 ELSE 0 END), 0) AS err
                        FROM grac_practice.asset_discovery_observation o WHERE o.batch_id = b.batch_id) x
         WHERE b.batch_id = @batch;
        UPDATE s
           SET last_batch_id = @batch, last_run_dt = SYSUTCDATETIME(), last_run_status = b.status
          FROM grac_practice.asset_discovery_source s
          JOIN grac_practice.asset_discovery_batch b ON b.batch_id = @batch
         WHERE s.source_id = @source_id;

        -- Retention (5.6.1): raw payloads, then observations nothing refers to.
        UPDATE grac_practice.asset_discovery_observation
           SET payload_json = NULL
         WHERE source_id = @source_id AND payload_json IS NOT NULL AND entered_dt < DATEADD(DAY, -@raw_days, SYSUTCDATETIME());
        DELETE o FROM grac_practice.asset_discovery_observation o
         WHERE o.source_id = @source_id AND o.entered_dt < DATEADD(DAY, -@obs_days, SYSUTCDATETIME())
           AND NOT EXISTS (SELECT 1 FROM grac_practice.asset_reconciliation_exception e WHERE e.observation_id = o.observation_id);
        INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
        SELECT N'asset-discovery-batch', b.batch_id, N'INGEST', NULL,
               (SELECT b.batch_reference AS batchReference, b.channel AS channel, b.status AS status, b.record_count AS records,
                       b.updated_count AS updated, b.exception_count AS exceptions, b.error_count AS errors, b.rule_set_version AS ruleSetVersion
                   FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
               N'Active', @actor
          FROM grac_practice.asset_discovery_batch b WHERE b.batch_id = @batch;
        SET @existing = @batch;
    END

    SELECT b.batch_id AS BatchId, b.batch_reference AS BatchReference, b.channel AS Channel, b.status AS Status, b.record_count AS RecordCount,
           b.updated_count AS UpdatedCount, b.no_change_count AS NoChangeCount, b.exception_count AS ExceptionCount,
           b.error_count AS ErrorCount, b.rule_set_version AS RuleSetVersion, b.received_dt AS ReceivedDt, b.completed_dt AS CompletedDt,
           @repeat AS IsRepeat
      FROM grac_practice.asset_discovery_batch b WHERE b.batch_id = @existing;
    SELECT o.record_no AS RecordNo, o.external_key AS ExternalKey, o.outcome AS Outcome, o.match_score AS MatchScore,
           o.matched_asset_id AS MatchedAssetId, a.asset_name AS MatchedAssetName, o.matched_rules AS MatchedRules, o.result_text AS ResultText
      FROM grac_practice.asset_discovery_observation o
      LEFT JOIN grac_practice.organization_dependency_asset a ON a.asset_id = o.matched_asset_id
     WHERE o.batch_id = @existing
     ORDER BY o.record_no;
END
GO
PRINT '442: reconciliation engine created.';
GO

-- =====================================================================
-- 7. Reconciliation queue (5.6.3; D102-D104)
-- =====================================================================
-- Actions:
--   Suggested match / Manual review / New candidate:  LINK (to @asset_id, or the
--       suggested asset), IGNORE (note)
--   Potential duplicate:  LINK (to one of the two assets), NOT_DUPLICATE (note; the
--       pair is not raised again), IGNORE (note)
--   Conflict:  ACCEPT_OBSERVED (the observed value is written), KEEP_CURRENT (note)
-- Linking applies the observation to the asset (confirmed link) and closes
-- the other open match exceptions of the same source record.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_reconciliation_resolve
    @organization_id         BIGINT,
    @exception_id            BIGINT,
    @action                  NVARCHAR(20),
    @asset_id                BIGINT         = NULL,
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
    DECLARE @found BIT = 0, @kind NVARCHAR(16), @status NVARCHAR(10), @rv BIGINT, @obs BIGINT, @source BIGINT, @key NVARCHAR(200),
            @exc_asset BIGINT, @other BIGINT, @field NVARCHAR(100), @observed NVARCHAR(400), @score INT, @payload NVARCHAR(MAX);
    SELECT @found = 1, @kind = e.exception_kind, @status = e.status, @rv = CONVERT(BIGINT, e.record_version), @obs = e.observation_id,
           @source = e.source_id, @key = e.external_key, @exc_asset = e.asset_id, @other = e.other_asset_id, @field = e.field_key,
           @observed = e.observed_value, @score = e.match_score, @payload = o.payload_json
      FROM grac_practice.asset_reconciliation_exception e
      JOIN grac_practice.asset_discovery_observation o ON o.observation_id = e.observation_id
     WHERE e.exception_id = @exception_id AND e.organization_id = @organization_id;
    IF @found = 0 THROW 54773, 'Reconciliation exception not found for this organization.', 1;
    IF @expected_record_version IS NOT NULL AND @expected_record_version <> @rv
        THROW 54774, 'The exception was changed by someone else; reload it and try again.', 1;
    IF @status <> N'OPEN' THROW 54775, 'This exception is already resolved.', 1;
    IF NOT ((@kind IN (N'SUGGESTED_MATCH', N'MANUAL_REVIEW', N'NEW_CANDIDATE') AND @action IN (N'LINK', N'IGNORE'))
         OR (@kind = N'DUPLICATE' AND @action IN (N'LINK', N'NOT_DUPLICATE', N'IGNORE'))
         OR (@kind = N'CONFLICT' AND @action IN (N'ACCEPT_OBSERVED', N'KEEP_CURRENT')))
        THROW 54776, 'That action is not available for this exception.', 1;
    IF @action IN (N'IGNORE', N'NOT_DUPLICATE', N'KEEP_CURRENT') AND @note IS NULL
        THROW 54778, 'Record the reason in the note.', 1;
    IF @action = N'LINK'
    BEGIN
        SET @asset_id = COALESCE(@asset_id, CASE WHEN @kind = N'SUGGESTED_MATCH' THEN @exc_asset END);
        IF @asset_id IS NULL OR (@kind = N'DUPLICATE' AND @asset_id NOT IN (@exc_asset, @other))
           OR NOT EXISTS (SELECT 1 FROM grac_practice.organization_dependency_asset a
                            LEFT JOIN grac_practice.entity_status_master s ON s.entity_status_id = a.current_status_id
                           WHERE a.asset_id = @asset_id AND a.organization_id = @organization_id
                             AND ISNULL(s.status_code, N'ACTIVE') NOT IN (N'DISPOSED', N'ARCHIVED'))
            THROW 54777, 'Select the register asset to link (for a duplicate, one of the two assets).', 1;
        IF @payload IS NULL
            THROW 54776, 'The observation details are past their retention; wait for the next observation of this record.', 1;
    END
    IF @action = N'ACCEPT_OBSERVED' AND @payload IS NULL AND @observed IS NULL
        THROW 54776, 'The observed value is no longer available.', 1;

    DECLARE @upd INT, @conf INT, @result NVARCHAR(20) = @action;
    BEGIN TRAN;
    IF @action = N'LINK'
    BEGIN
        EXEC grac_practice.sp_asset_discovery_apply @observation_id = @obs, @asset_id = @asset_id, @link_method = N'CONFIRMED',
             @match_score = @score, @actor = @actor, @out_updated = @upd OUTPUT, @out_conflicts = @conf OUTPUT;
        UPDATE grac_practice.asset_reconciliation_exception
           SET status = N'RESOLVED', resolution = N'LINKED', resolution_note = ISNULL(@note, CONCAT(N'Linked to asset ', @asset_id, N'.')),
               resolved_by = @actor, resolved_dt = SYSUTCDATETIME(), asset_id = @asset_id, updated_dt = SYSUTCDATETIME()
         WHERE status = N'OPEN' AND exception_kind IN (N'SUGGESTED_MATCH', N'MANUAL_REVIEW', N'NEW_CANDIDATE', N'DUPLICATE')
           AND (exception_id = @exception_id OR (@key IS NOT NULL AND source_id = @source AND external_key = @key));
        UPDATE grac_practice.asset_discovery_observation
           SET matched_asset_id = @asset_id,
               result_text = LEFT(CONCAT(result_text, N' Linked by ', @actor, N': ', @upd, N' field(s) updated, ', @conf, N' conflict(s).'), 1000)
         WHERE observation_id = @obs;
    END
    ELSE IF @action = N'ACCEPT_OBSERVED'
    BEGIN
        EXEC grac_practice.sp_asset_field_value_set @asset_id = @exc_asset, @field_key = @field, @value = @observed, @actor = @actor;
        UPDATE grac_practice.asset_attribute_source SET applied = 1 WHERE asset_id = @exc_asset AND field_key = @field AND source_id = @source;
        INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
        VALUES (N'asset-register', @exc_asset, N'DISCOVERY', NULL,
                (SELECT @exception_id AS exceptionId, @field AS fieldKey, @observed AS acceptedValue FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
                N'Active', @actor);
    END
    ELSE IF @action = N'NOT_DUPLICATE'
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM grac_practice.asset_duplicate_decision
                        WHERE asset_id_low = CASE WHEN @exc_asset < @other THEN @exc_asset ELSE @other END
                          AND asset_id_high = CASE WHEN @exc_asset < @other THEN @other ELSE @exc_asset END)
            INSERT grac_practice.asset_duplicate_decision (asset_id_low, asset_id_high, note, decided_by)
            VALUES (CASE WHEN @exc_asset < @other THEN @exc_asset ELSE @other END,
                    CASE WHEN @exc_asset < @other THEN @other ELSE @exc_asset END, @note, @actor);
    END
    IF @action <> N'LINK'
        UPDATE grac_practice.asset_reconciliation_exception
           SET status = N'RESOLVED', resolution = @action, resolution_note = @note, resolved_by = @actor, resolved_dt = SYSUTCDATETIME(),
               updated_dt = SYSUTCDATETIME()
         WHERE exception_id = @exception_id;
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-reconciliation-exception', @exception_id, @action, N'{"status":"OPEN"}',
            (SELECT @action AS resolution, @asset_id AS assetId, @note AS note FOR JSON PATH, WITHOUT_ARRAY_WRAPPER), N'Active', @actor);
    COMMIT;
    SELECT @exception_id AS ExceptionId, @result AS Result;
END
GO
PRINT '442: reconciliation queue created.';
GO

-- =====================================================================
-- 8. Data confidence and freshness (5.6.4; D105)
-- =====================================================================
-- Per asset in use: source links, best identity score, last observation,
-- links fresh within the expected interval x stale multiplier, open
-- conflicts, attributes a source reports differently and not applied, the
-- last verified date. Overall: Conflicting (open conflict) > Stale (linked,
-- nothing fresh) > Verified (verified within the window) > Probable (fresh
-- link at or above the auto-match score) > Unverified.
CREATE OR ALTER FUNCTION grac_practice.fn_asset_discovery_confidence (@organization_id BIGINT)
RETURNS TABLE
AS
RETURN
    SELECT a.asset_id AS AssetId, a.asset_name AS AssetName, ty.asset_type_name AS AssetTypeName,
           ISNULL(l.links, 0) AS LinkCount, l.best_score AS IdentityScore, l.last_seen AS LastObservedDt,
           ISNULL(l.fresh_links, 0) AS FreshLinkCount,
           CASE WHEN l.last_seen IS NULL THEN NULL ELSE DATEDIFF(HOUR, l.last_seen, SYSUTCDATETIME()) END AS AgeHours,
           ISNULL(c.conflicts, 0) AS OpenConflictCount, ISNULL(d.disagreements, 0) AS AttributeDisagreementCount,
           vd.verified_date AS LastVerifiedDate,
           CASE WHEN ISNULL(c.conflicts, 0) > 0 THEN N'CONFLICTING'
                WHEN ISNULL(l.links, 0) > 0 AND ISNULL(l.fresh_links, 0) = 0 THEN N'STALE'
                WHEN vd.verified_date >= DATEADD(DAY, -st.verification_days, CAST(SYSUTCDATETIME() AS DATE)) THEN N'VERIFIED'
                WHEN ISNULL(l.fresh_links, 0) > 0 AND l.best_score >= st.auto_match_score THEN N'PROBABLE'
                ELSE N'UNVERIFIED' END AS OverallStatus
      FROM grac_practice.organization_dependency_asset a
      LEFT JOIN grac_practice.entity_status_master s ON s.entity_status_id = a.current_status_id
      LEFT JOIN grac_practice.dependency_asset_type_master ty ON ty.asset_type_id = a.asset_type_id
     CROSS APPLY (SELECT ISNULL(MAX(x.stale_multiplier), 3) AS stale_multiplier, ISNULL(MAX(x.verification_days), 365) AS verification_days,
                         ISNULL(MAX(x.auto_match_score), 90) AS auto_match_score
                    FROM grac_practice.asset_discovery_setting x WHERE x.organization_id = @organization_id) st
     -- the freshness flag is computed per link first: an aggregate cannot mix the
     -- outer settings with inner columns (Msg 8124).
     OUTER APPLY (SELECT COUNT(*) AS links, MAX(k.identity_score) AS best_score, MAX(k.last_seen_dt) AS last_seen,
                         SUM(fr.is_fresh) AS fresh_links
                    FROM grac_practice.asset_discovery_link k
                    JOIN grac_practice.asset_discovery_source src ON src.source_id = k.source_id
                   CROSS APPLY (SELECT CASE WHEN k.last_seen_dt >= DATEADD(HOUR, -src.expected_interval_hours * st.stale_multiplier,
                                                                            SYSUTCDATETIME()) THEN 1 ELSE 0 END AS is_fresh) fr
                   WHERE k.asset_id = a.asset_id) l
     OUTER APPLY (SELECT COUNT(*) AS conflicts FROM grac_practice.asset_reconciliation_exception e
                   WHERE e.asset_id = a.asset_id AND e.exception_kind = N'CONFLICT' AND e.status = N'OPEN') c
     OUTER APPLY (SELECT COUNT(*) AS disagreements FROM grac_practice.asset_attribute_source x
                   WHERE x.asset_id = a.asset_id AND x.applied = 0) d
     OUTER APPLY (SELECT MAX(v.value_date) AS verified_date FROM grac_practice.asset_field_value v
                    JOIN grac_practice.asset_field_definition f ON f.field_definition_id = v.field_definition_id AND f.field_key = N'last_verified_date'
                   WHERE v.asset_id = a.asset_id) vd
     WHERE a.organization_id = @organization_id
       AND ISNULL(s.status_code, N'ACTIVE') NOT IN (N'DISPOSED', N'ARCHIVED');
GO
PRINT '442: data confidence created.';
GO

-- =====================================================================
-- 9. Readers
-- =====================================================================
-- 1. settings  2. sources with health  3. field precedence  4. rules
-- 5. active employees  6. dictionary fields (writable by discovery or not).
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_discovery_config_get
    @organization_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 54760, 'Organization not found.', 1;
    EXEC grac_practice.sp_asset_discovery_defaults_ensure @organization_id = @organization_id;
    SELECT auto_match_score AS AutoMatchScore, suggested_score AS SuggestedScore, manual_review_score AS ManualReviewScore,
           stale_multiplier AS StaleMultiplier, verification_days AS VerificationDays, create_conflict_tasks AS CreateConflictTasks,
           rule_set_version AS RuleSetVersion
      FROM grac_practice.asset_discovery_setting WHERE organization_id = @organization_id;
    SELECT s.source_id AS SourceId, s.source_code AS SourceCode, s.source_name AS SourceName, s.source_type AS SourceType,
           s.collection_mode AS CollectionMode, s.scope_text AS ScopeText, s.mapping_version AS MappingVersion,
           s.owner_employee_id AS OwnerEmployeeId, ow.employee_name AS OwnerName, s.credential_reference AS CredentialReference,
           s.trust_level AS TrustLevel, s.expected_interval_hours AS ExpectedIntervalHours, s.raw_retention_days AS RawRetentionDays,
           s.observation_retention_days AS ObservationRetentionDays, s.is_active AS IsActive, s.last_run_dt AS LastRunDt,
           s.last_run_status AS LastRunStatus, DATEADD(HOUR, s.expected_interval_hours, s.last_run_dt) AS NextRunDueDt,
           CASE WHEN s.last_run_dt IS NULL THEN N'NEVER'
                WHEN s.last_run_status = N'FAILED' THEN N'FAILED'
                WHEN s.last_run_status = N'PARTIAL' OR DATEADD(HOUR, s.expected_interval_hours, s.last_run_dt) < SYSUTCDATETIME() THEN N'WARNING'
                ELSE N'SUCCESS' END AS HealthStatus,
           (SELECT COUNT(*) FROM grac_practice.asset_discovery_link l WHERE l.source_id = s.source_id) AS LinkCount,
           CONVERT(BIGINT, s.record_version) AS RecordVersion
      FROM grac_practice.asset_discovery_source s
      LEFT JOIN grac_practice.organization_employee ow ON ow.employee_id = s.owner_employee_id
     WHERE s.organization_id = @organization_id
     ORDER BY s.source_name;
    SELECT p.source_id AS SourceId, p.field_key AS FieldKey, f.display_label AS FieldLabel, p.source_role AS SourceRole, p.priority AS Priority
      FROM grac_practice.asset_discovery_priority p
      JOIN grac_practice.asset_discovery_source s ON s.source_id = p.source_id AND s.organization_id = @organization_id
      LEFT JOIN grac_practice.asset_field_definition f ON f.field_key = p.field_key
     ORDER BY p.source_id, p.priority, p.field_key;
    SELECT rule_id AS RuleId, rule_name AS RuleName, attribute_keys AS AttributeKeys, strength AS Strength, weight AS Weight,
           is_active AS IsActive, display_order AS DisplayOrder
      FROM grac_practice.asset_identification_rule WHERE organization_id = @organization_id
     ORDER BY display_order, rule_name;
    SELECT employee_id AS EmployeeId, employee_name AS EmployeeName
      FROM grac_practice.organization_employee WHERE organization_id = @organization_id AND status = N'Active' ORDER BY employee_name;
    SELECT f.field_key AS FieldKey, f.display_label AS FieldLabel, f.data_type_code AS DataTypeCode,
           CAST(CASE WHEN f.storage_kind = N'VALUE' AND f.data_type_code IN (N'TEXT', N'MULTILINE', N'DECIMAL', N'PERCENT', N'QUANTITY_UNIT',
                                                                            N'DATE', N'IP_ADDRESS', N'IP_LIST') THEN 1 ELSE 0 END AS BIT) AS IsWritable
      FROM grac_practice.asset_field_definition f
     WHERE f.storage_kind IN (N'VALUE', N'COLUMN')
     ORDER BY f.display_label;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_asset_discovery_batches
    @organization_id BIGINT,
    @source_id       BIGINT = NULL,
    @page_number     INT    = 1,
    @page_size       INT    = 25
AS
BEGIN
    SET NOCOUNT ON;
    SET @page_number = CASE WHEN ISNULL(@page_number, 1) < 1 THEN 1 ELSE @page_number END;
    SET @page_size = CASE WHEN ISNULL(@page_size, 25) < 1 THEN 25 WHEN @page_size > 200 THEN 200 ELSE @page_size END;
    SELECT b.batch_id AS BatchId, b.batch_reference AS BatchReference, b.source_id AS SourceId, s.source_name AS SourceName,
           b.channel AS Channel, b.status AS Status, b.record_count AS RecordCount, b.updated_count AS UpdatedCount,
           b.no_change_count AS NoChangeCount, b.exception_count AS ExceptionCount, b.error_count AS ErrorCount,
           b.rule_set_version AS RuleSetVersion, b.received_dt AS ReceivedDt, b.completed_dt AS CompletedDt, b.entered_by AS EnteredBy,
           COUNT(*) OVER () AS TotalRows
      FROM grac_practice.asset_discovery_batch b
      JOIN grac_practice.asset_discovery_source s ON s.source_id = b.source_id
     WHERE b.organization_id = @organization_id AND (@source_id IS NULL OR b.source_id = @source_id)
     ORDER BY b.batch_id DESC
    OFFSET (@page_number - 1) * @page_size ROWS FETCH NEXT @page_size ROWS ONLY;
END
GO

-- One batch: 1. batch  2. records.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_discovery_batch_get
    @organization_id BIGINT,
    @batch_id        BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.asset_discovery_batch WHERE batch_id = @batch_id AND organization_id = @organization_id)
        THROW 54779, 'Discovery batch not found for this organization.', 1;
    SELECT b.batch_id AS BatchId, b.batch_reference AS BatchReference, s.source_name AS SourceName, b.channel AS Channel, b.status AS Status,
           b.record_count AS RecordCount, b.updated_count AS UpdatedCount, b.no_change_count AS NoChangeCount,
           b.exception_count AS ExceptionCount, b.error_count AS ErrorCount, b.rule_set_version AS RuleSetVersion,
           b.received_dt AS ReceivedDt, b.completed_dt AS CompletedDt, b.entered_by AS EnteredBy
      FROM grac_practice.asset_discovery_batch b
      JOIN grac_practice.asset_discovery_source s ON s.source_id = b.source_id
     WHERE b.batch_id = @batch_id;
    SELECT o.observation_id AS ObservationId, o.record_no AS RecordNo, o.external_key AS ExternalKey, o.observed_dt AS ObservedDt,
           o.outcome AS Outcome, o.match_score AS MatchScore, o.matched_asset_id AS MatchedAssetId, a.asset_name AS MatchedAssetName,
           o.second_asset_id AS SecondAssetId, a2.asset_name AS SecondAssetName, o.second_score AS SecondScore,
           o.matched_rules AS MatchedRules, o.result_text AS ResultText, o.payload_json AS PayloadJson
      FROM grac_practice.asset_discovery_observation o
      LEFT JOIN grac_practice.organization_dependency_asset a ON a.asset_id = o.matched_asset_id
      LEFT JOIN grac_practice.organization_dependency_asset a2 ON a2.asset_id = o.second_asset_id
     WHERE o.batch_id = @batch_id
     ORDER BY o.record_no;
END
GO

-- Reconciliation queue. @status: NULL = open, RESOLVED, ALL.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_reconciliation_exceptions
    @organization_id BIGINT,
    @status          NVARCHAR(10)  = NULL,
    @exception_kind  NVARCHAR(16)  = NULL,
    @source_id       BIGINT        = NULL,
    @asset_id        BIGINT        = NULL,
    @search          NVARCHAR(200) = NULL,
    @page_number     INT           = 1,
    @page_size       INT           = 25
AS
BEGIN
    SET NOCOUNT ON;
    SET @status = NULLIF(UPPER(LTRIM(RTRIM(@status))), N'');
    SET @exception_kind = NULLIF(UPPER(LTRIM(RTRIM(@exception_kind))), N'');
    SET @search = NULLIF(LTRIM(RTRIM(@search)), N'');
    SET @page_number = CASE WHEN ISNULL(@page_number, 1) < 1 THEN 1 ELSE @page_number END;
    SET @page_size = CASE WHEN ISNULL(@page_size, 25) < 1 THEN 25 WHEN @page_size > 200 THEN 200 ELSE @page_size END;
    SELECT e.exception_id AS ExceptionId, e.exception_kind AS ExceptionKind, e.status AS Status, e.source_id AS SourceId,
           s.source_name AS SourceName, e.external_key AS ExternalKey, e.asset_id AS AssetId, a.asset_name AS AssetName,
           e.other_asset_id AS OtherAssetId, a2.asset_name AS OtherAssetName, e.field_key AS FieldKey, f.display_label AS FieldLabel,
           e.current_value AS CurrentValue, e.observed_value AS ObservedValue, e.match_score AS MatchScore, e.raised_count AS RaisedCount,
           e.observation_id AS ObservationId, o.observed_dt AS ObservedDt, o.matched_rules AS MatchedRules, o.payload_json AS PayloadJson,
           e.task_id AS TaskId, t.task_number AS TaskNumber, e.resolution AS Resolution, e.resolution_note AS ResolutionNote,
           e.resolved_by AS ResolvedBy, e.resolved_dt AS ResolvedDt, e.entered_dt AS RaisedDt,
           CONVERT(BIGINT, e.record_version) AS RecordVersion,
           COUNT(*) OVER () AS TotalRows
      FROM grac_practice.asset_reconciliation_exception e
      JOIN grac_practice.asset_discovery_source s ON s.source_id = e.source_id
      JOIN grac_practice.asset_discovery_observation o ON o.observation_id = e.observation_id
      LEFT JOIN grac_practice.organization_dependency_asset a ON a.asset_id = e.asset_id
      LEFT JOIN grac_practice.organization_dependency_asset a2 ON a2.asset_id = e.other_asset_id
      LEFT JOIN grac_practice.asset_field_definition f ON f.field_key = e.field_key
      LEFT JOIN grac_practice.practice_task t ON t.task_id = e.task_id
     WHERE e.organization_id = @organization_id
       AND ((@status IS NULL AND e.status = N'OPEN') OR @status = N'ALL' OR e.status = @status)
       AND (@exception_kind IS NULL OR e.exception_kind = @exception_kind)
       AND (@source_id IS NULL OR e.source_id = @source_id)
       AND (@asset_id IS NULL OR e.asset_id = @asset_id OR e.other_asset_id = @asset_id)
       AND (@search IS NULL OR a.asset_name LIKE N'%' + @search + N'%' OR e.external_key LIKE N'%' + @search + N'%'
            OR a2.asset_name LIKE N'%' + @search + N'%')
     ORDER BY CASE e.exception_kind WHEN N'CONFLICT' THEN 0 WHEN N'DUPLICATE' THEN 1 WHEN N'SUGGESTED_MATCH' THEN 2
                                    WHEN N'MANUAL_REVIEW' THEN 3 ELSE 4 END, e.exception_id DESC
    OFFSET (@page_number - 1) * @page_size ROWS FETCH NEXT @page_size ROWS ONLY;
END
GO

-- Data confidence list. @status: NULL = every asset, or one overall status.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_discovery_confidence
    @organization_id BIGINT,
    @status          NVARCHAR(12)  = NULL,
    @search          NVARCHAR(200) = NULL,
    @page_number     INT           = 1,
    @page_size       INT           = 25
AS
BEGIN
    SET NOCOUNT ON;
    SET @status = NULLIF(UPPER(LTRIM(RTRIM(@status))), N'');
    SET @search = NULLIF(LTRIM(RTRIM(@search)), N'');
    SET @page_number = CASE WHEN ISNULL(@page_number, 1) < 1 THEN 1 ELSE @page_number END;
    SET @page_size = CASE WHEN ISNULL(@page_size, 25) < 1 THEN 25 WHEN @page_size > 200 THEN 200 ELSE @page_size END;
    SELECT c.*, COUNT(*) OVER () AS TotalRows
      FROM grac_practice.fn_asset_discovery_confidence(@organization_id) c
     WHERE (@status IS NULL OR c.OverallStatus = @status)
       AND (@search IS NULL OR c.AssetName LIKE N'%' + @search + N'%' OR c.AssetTypeName LIKE N'%' + @search + N'%')
     ORDER BY CASE c.OverallStatus WHEN N'CONFLICTING' THEN 0 WHEN N'STALE' THEN 1 WHEN N'UNVERIFIED' THEN 2 WHEN N'PROBABLE' THEN 3 ELSE 4 END,
              c.AssetName
    OFFSET (@page_number - 1) * @page_size ROWS FETCH NEXT @page_size ROWS ONLY;
END
GO

-- One asset: 1. confidence  2. source links  3. values per source
-- (with the register value)  4. open exceptions.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_discovery_asset_get
    @organization_id BIGINT,
    @asset_id        BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization_dependency_asset WHERE asset_id = @asset_id AND organization_id = @organization_id)
        THROW 54777, 'Asset not found for this organization.', 1;
    SELECT * FROM grac_practice.fn_asset_discovery_confidence(@organization_id) WHERE AssetId = @asset_id;
    SELECT l.link_id AS LinkId, l.source_id AS SourceId, s.source_name AS SourceName, l.external_key AS ExternalKey,
           l.identity_score AS IdentityScore, l.link_method AS LinkMethod, l.first_seen_dt AS FirstSeenDt, l.last_seen_dt AS LastSeenDt,
           DATEDIFF(HOUR, l.last_seen_dt, SYSUTCDATETIME()) AS AgeHours, s.expected_interval_hours AS ExpectedIntervalHours
      FROM grac_practice.asset_discovery_link l
      JOIN grac_practice.asset_discovery_source s ON s.source_id = l.source_id
     WHERE l.asset_id = @asset_id
     ORDER BY s.source_name;
    SELECT x.field_key AS FieldKey, f.display_label AS FieldLabel, s.source_name AS SourceName, ISNULL(p.source_role, N'CONTRIBUTING') AS SourceRole,
           x.observed_value AS ObservedValue, x.observed_dt AS ObservedDt, x.applied AS Applied, v.value_text AS RegisterValue
      FROM grac_practice.asset_attribute_source x
      JOIN grac_practice.asset_discovery_source s ON s.source_id = x.source_id
      LEFT JOIN grac_practice.asset_discovery_priority p ON p.source_id = x.source_id AND p.field_key = x.field_key
      LEFT JOIN grac_practice.asset_field_definition f ON f.field_key = x.field_key
      LEFT JOIN grac_practice.asset_field_value v ON v.asset_id = x.asset_id AND v.field_definition_id = f.field_definition_id
     WHERE x.asset_id = @asset_id
     ORDER BY f.display_label, s.source_name;
    SELECT e.exception_id AS ExceptionId, e.exception_kind AS ExceptionKind, e.field_key AS FieldKey, e.current_value AS CurrentValue,
           e.observed_value AS ObservedValue, e.match_score AS MatchScore, e.entered_dt AS RaisedDt
      FROM grac_practice.asset_reconciliation_exception e
     WHERE (e.asset_id = @asset_id OR e.other_asset_id = @asset_id) AND e.status = N'OPEN' AND e.organization_id = @organization_id
     ORDER BY e.exception_id DESC;
END
GO
PRINT '442: readers created.';
GO

-- =====================================================================
-- 10. Menu: Asset & Contract -> Asset Discovery (also carried in 274)
-- =====================================================================
MERGE grac_practice.menu_master AS t
USING (VALUES
    (N'asset-discovery', N'Asset Discovery', N'Practice/Index/asset-discovery', 363, N'satellite-dish', N'Asset & Contract')
) AS s(menu_key, menu_name, menu_url, display_order, icon_class, module_type)
ON t.menu_key = s.menu_key
WHEN MATCHED AND (ISNULL(t.menu_name, N'') <> s.menu_name OR ISNULL(t.menu_url, N'') <> s.menu_url
               OR t.display_order <> s.display_order OR ISNULL(t.icon_class, N'') <> s.icon_class
               OR ISNULL(t.module_type, N'') <> s.module_type OR t.status <> N'Active') THEN UPDATE SET
    menu_name = s.menu_name, menu_url = s.menu_url, display_order = s.display_order, icon_class = s.icon_class,
    module_type = s.module_type, status = N'Active', updated_by = N'seed-442', updated_dt = SYSUTCDATETIME()
WHEN NOT MATCHED BY TARGET THEN
    INSERT (menu_key, menu_name, menu_url, display_order, icon_class, module_type, status, entered_by)
    VALUES (s.menu_key, s.menu_name, s.menu_url, s.display_order, s.icon_class, s.module_type, N'Active', N'seed-442');
PRINT CONCAT('442: menu row upserted: ', @@ROWCOUNT);
GO

UPDATE c
   SET parent_menu_id = p.menu_id, updated_by = N'seed-442', updated_dt = SYSUTCDATETIME()
  FROM grac_practice.menu_master c
  JOIN grac_practice.menu_master p ON p.menu_key = N'nav-asset-contract'
 WHERE c.menu_key = N'asset-discovery' AND ISNULL(c.parent_menu_id, -1) <> p.menu_id;
GO

DECLARE @active_rs INT = (
    SELECT TOP 1 record_status_id FROM grac_practice.record_status_master
     WHERE status_code = N'Active' OR status_name = N'Active' ORDER BY record_status_id);
IF @active_rs IS NULL SET @active_rs = 1;
INSERT grac_practice.organization_role_menu_permission
    (role_id, menu_id, can_view, can_add, can_edit, can_delete, can_approve, status, record_status_id, entered_by, entered_dt)
SELECT r.role_id, m.menu_id, 1, 1, 1, 0, 1, N'Active', @active_rs, N'seed-442', SYSUTCDATETIME()
  FROM grac_practice.organization_role r
  JOIN grac_practice.menu_master m ON m.menu_key = N'asset-discovery'
 WHERE r.role_name = N'Admin' AND r.status = N'Active'
   AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_role_menu_permission e
                    WHERE e.role_id = r.role_id AND e.menu_id = m.menu_id);
PRINT CONCAT('442: Admin grants inserted: ', @@ROWCOUNT);
GO

-- =====================================================================
-- Verification
-- =====================================================================
SELECT '442-a tables and task type' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.asset_discovery_source','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.asset_discovery_priority','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.asset_identification_rule','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.asset_discovery_setting','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.asset_discovery_batch','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.asset_discovery_observation','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.asset_discovery_link','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.asset_attribute_source','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.asset_reconciliation_exception','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.asset_duplicate_decision','U') IS NOT NULL
             AND EXISTS (SELECT 1 FROM grac_practice.task_type_master WHERE type_code = N'AssetReconciliation')
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '442-b functions and procedures present',
       CASE WHEN OBJECT_ID('grac_practice.fn_asset_norm') IS NOT NULL
             AND OBJECT_ID('grac_practice.fn_asset_discovery_confidence') IS NOT NULL
             AND (SELECT COUNT(*) FROM sys.procedures WHERE SCHEMA_NAME(schema_id) = 'grac_practice'
                   AND name IN ('sp_asset_discovery_defaults_ensure', 'sp_asset_discovery_source_save', 'sp_asset_discovery_priorities_save',
                                'sp_asset_identification_rule_save', 'sp_asset_discovery_setting_save', 'sp_asset_discovery_identity_load',
                                'sp_asset_reconciliation_exception_raise', 'sp_asset_discovery_apply', 'sp_asset_discovery_reconcile',
                                'sp_asset_discovery_ingest', 'sp_asset_reconciliation_resolve', 'sp_asset_discovery_config_get',
                                'sp_asset_discovery_batches', 'sp_asset_discovery_batch_get', 'sp_asset_reconciliation_exceptions',
                                'sp_asset_discovery_confidence', 'sp_asset_discovery_asset_get')) = 17
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '442-c normalization (MAC separators, hostname short name, blank)',
       CASE WHEN grac_practice.fn_asset_norm(N'mac_address', N'aa:bb-cc.dd:ee:ff') = N'AABBCCDDEEFF'
             AND grac_practice.fn_asset_norm(N'hostname', N'srv01.corp.local') = N'SRV01'
             AND grac_practice.fn_asset_norm(N'serial_number', N'  abc123 ') = N'ABC123'
             AND grac_practice.fn_asset_norm(N'serial_number', N'   ') IS NULL
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '442-d menu row Active under Asset & Contract',
       CASE WHEN EXISTS (SELECT 1 FROM grac_practice.menu_master c
                           JOIN grac_practice.menu_master p ON p.menu_id = c.parent_menu_id AND p.menu_key = N'nav-asset-contract'
                          WHERE c.menu_key = N'asset-discovery' AND c.status = N'Active') THEN 'PASS' ELSE 'FAIL' END;
GO

-- =====================================================================
-- UAT (after deploying the API + Web build; re-login for the menu grant)
--   Needs: asset SRV1 with serial "SN-1", make / model set, hostname
--   "srv1", asset tag "T-1"; asset SRV2 with hostname "srv2"; users E (edit)
--   and A (approve).
--   1. Asset Discovery -> Sources: add CMDB-SCAN (Discovery, Batch, trust
--      100, interval 24 h). Field precedence: hostname golden, ip_address
--      contributing. Identification rules: the ten defaults are listed.
--   2. Import: batch B1, records
--        [{"externalKey":"d-1","attributes":{"asset_tag":"T-1","hostname":"srv1","ip_address":"10.0.0.5","serial_number":"SN-9"}},
--         {"externalKey":"d-2","attributes":{"hostname":"newbox"}},
--         {"externalKey":"d-3","attributes":"bad"}]
--      -> d-1 Updated (asset tag match; IP filled; serial differs and the
--      source is not golden -> Conflict with an owner task), d-2 New
--      candidate, d-3 Error; batch Partial with per-record results.
--   3. Import B1 again -> the same batch is returned, nothing reprocessed.
--      Import B2 with the d-1 record unchanged -> No change (freshness only).
--   4. Reconciliation queue: Conflict -> Keep current (note) or Accept
--      observed (A). New candidate d-2 -> Link to SRV2 (E) -> the hostname
--      "newbox" is a conflict on SRV2 (hostname golden would overwrite: set
--      hostname golden for this source first to see the overwrite).
--   5. A record matching SRV1 and SRV2 at the suggested score -> Potential
--      duplicate; Not a duplicate (note) -> a repeat no longer raises it.
--   6. Data confidence: SRV1 Probable (fresh, auto match) or Conflicting
--      while its conflict is open; set the source interval to 1 h and wait
--      past 3 h -> Stale; a recent last verified date -> Verified.
-- =====================================================================
