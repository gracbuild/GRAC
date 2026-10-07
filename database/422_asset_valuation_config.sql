-- =====================================================================
-- 422  Asset valuation configuration -- CIA scales, valuation method,
--      Asset Value bands, criticality scale
--      (Asset & Contract Management, Phase 2 increment 3)
--
-- REQUEST
-- -------
--   BRD v1.7 section 5.1.18 (Asset Value and CIA Valuation Framework)
--   and 5.1.18.5 (CIA and Criticality Administration). Continues 420/421;
--   plan in docs/asset-contract-management.md.
--
-- WHAT THIS DOES
-- --------------
--   1. One versioned "valuation configuration" per organization
--      (tenant-scoped, effective-dated, approval-controlled -- 5.1.18.5):
--        asset_valuation_config         header: valuation method
--                                       (MAXIMUM | WEIGHTED_AVERAGE |
--                                       SUMMATION), C/I/A weights, decimal
--                                       places, rounding rule, override
--                                       permission, lifecycle, effective dates
--        asset_cia_scale_level          score / label / impact description per
--                                       dimension (C, I, A)       (5.1.18.5.1)
--        asset_value_band               non-overlapping score ranges ->
--                                       category label            (5.1.18.5.4)
--        asset_criticality_level        criticality score / label / impact /
--                                       review frequency; optionally mapped
--                                       to the existing global criticality_master
--                                       row so current asset data keeps its
--                                       meaning                   (5.1.18.5.5)
--   2. Lifecycle on the state-machine framework, entity type
--      'AssetValuationConfig': Draft -> Pending Approval -> Approved ->
--      Active -> Retired (5.1.18.5.8; "Review" is the Pending Approval step).
--      An Active version is immutable -- changes need a new version. One
--      Active and one working version per organization. Submitter cannot
--      approve. Activation retires the previous Active version.
--   3. Activation / approval are blocked unless (5.1.18.5.9):
--        * every dimension has at least two levels with distinct scores;
--        * Weighted Average weights total exactly 100;
--        * bands exist, do not overlap, leave no gap at the configured
--          precision, and cover the method's full possible score range;
--        * the criticality scale has at least one level, distinct scores.
--   4. fn_asset_value_calc -- the one calculation, used by the Calculator
--      tab now and by the Asset Register / imports / risk later:
--        MAXIMUM          MAX(C, I, A)
--        WEIGHTED_AVERAGE (C x WC + I x WI + A x WA) / 100
--        SUMMATION        C + I + A
--      rounded per the configuration, then mapped to its band. A score with
--      no band returns a NULL category (never a silent default -- 5.1.18.5.7).
--   5. Defaults for a new Draft: the BRD 5.1.18 1-5 scale (Negligible / Low
--      / Medium / High / Critical with the BRD impact text) for each
--      dimension, Maximum method, and the organization's current
--      criticality_master rows as the criticality scale. Value bands are
--      NOT pre-filled: the BRD names the categories (Low, Medium, High,
--      Critical) but not their score ranges, so the administrator sets them
--      and activation stays blocked until they do.
--   6. Template integration: the CIA rating fields (lookup CONFIG:CIA_SCALE)
--      now list the levels of the organization's Active configuration --
--      sp_asset_form_template_get and _readiness are re-issued; readiness
--      only warns CONFIG_PENDING when the organization has no Active
--      configuration.
--   7. Menu "Asset Valuation" (asset-valuation-config) under Asset &
--      Contract; Admin grant VIEW/ADD/EDIT/APPROVE (missing rows only).
--
-- NOT IN THIS INCREMENT: recalculating existing assets (there is no asset
--   value store until the Asset Register, Phase 4 -- the impact analysis
--   and controlled recalculation of 5.1.18.5.7/5.1.18.5.8 land with it);
--   per-scope (entity / category / type) configurations -- one per
--   organization for now; organization-specific option lists (423).
--
-- ERROR NUMBERS: 54250-54299
--   54250 organization not found          54251 configuration not found
--   54252 only a Draft can be changed     54253 changed by someone else
--   54254 working version already exists  54255 change reason required
--   54256 invalid method / rounding       54257 weights out of range
--   54258 dimension must be C, I or A     54259 score / label required
--   54260 duplicate score                 54261 band range invalid
--   54262 band overlaps another           54263 not ready (readiness errors)
--   54264 submitter cannot approve        54265 reason required
--   54266 effective-from in the future    54267 criticality mapping invalid
--   54268 level / band not found          54269 decimal places out of range
--   (illegal status moves: framework 53520 -> HTTP 409)
--
-- ALSO EDITED: 274_menu_master_seed.sql (menu row + parent link), API
--   (AssetConfig service/controller/models), Web proxy, PracticeScreen.cs,
--   Manage.cshtml, new partial + script asset-valuation-config.
-- DEPENDS ON: 035, 420, 421.
-- Rollback: 422_asset_valuation_config_rollback.sql
-- Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.asset_form_template_rule','U') IS NULL
   OR OBJECT_ID('grac_practice.sp_asset_form_template_evaluate','P') IS NULL
   OR OBJECT_ID('grac_practice.sp_pm_state_transition','P') IS NULL
   OR OBJECT_ID('grac_practice.criticality_master','U') IS NULL
   OR COL_LENGTH('grac_practice.criticality_master','criticality_name') IS NULL
BEGIN
    RAISERROR('ABORT (422): run 420_asset_form_templates.sql and 421_asset_form_rules.sql first.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. Tables
-- =====================================================================
IF OBJECT_ID('grac_practice.asset_valuation_config','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_valuation_config (
        config_id          BIGINT         IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_asset_val_config PRIMARY KEY,
        organization_id    BIGINT         NOT NULL
            CONSTRAINT fk_pm_asset_val_config_org REFERENCES grac_practice.organization(organization_id),
        config_name        NVARCHAR(200)  NOT NULL,
        version_no         INT            NOT NULL,
        current_status_id  INT            NOT NULL
            CONSTRAINT fk_pm_asset_val_config_status REFERENCES grac_practice.entity_status_master(entity_status_id),
        valuation_method   NVARCHAR(30)   NOT NULL CONSTRAINT df_pm_asset_val_config_method DEFAULT N'MAXIMUM'
            CONSTRAINT ck_pm_asset_val_config_method CHECK (valuation_method IN (N'MAXIMUM', N'WEIGHTED_AVERAGE', N'SUMMATION')),
        weight_c           DECIMAL(5, 2)  NOT NULL CONSTRAINT df_pm_asset_val_config_wc DEFAULT 34,
        weight_i           DECIMAL(5, 2)  NOT NULL CONSTRAINT df_pm_asset_val_config_wi DEFAULT 33,
        weight_a           DECIMAL(5, 2)  NOT NULL CONSTRAINT df_pm_asset_val_config_wa DEFAULT 33,
        decimal_places     TINYINT        NOT NULL CONSTRAINT df_pm_asset_val_config_dp DEFAULT 2
            CONSTRAINT ck_pm_asset_val_config_dp CHECK (decimal_places BETWEEN 0 AND 4),
        rounding_mode      NVARCHAR(20)   NOT NULL CONSTRAINT df_pm_asset_val_config_round DEFAULT N'ROUND_HALF_UP'
            CONSTRAINT ck_pm_asset_val_config_round CHECK (rounding_mode IN (N'ROUND_HALF_UP', N'ROUND_DOWN', N'ROUND_UP')),
        override_allowed   BIT            NOT NULL CONSTRAINT df_pm_asset_val_config_ovr DEFAULT 0,
        effective_from     DATE           NULL,
        effective_to       DATE           NULL,
        change_reason      NVARCHAR(1000) NULL,
        source_config_id   BIGINT         NULL
            CONSTRAINT fk_pm_asset_val_config_source REFERENCES grac_practice.asset_valuation_config(config_id),
        is_active_version  BIT            NOT NULL CONSTRAINT df_pm_asset_val_config_act DEFAULT 0,
        is_working_version BIT            NOT NULL CONSTRAINT df_pm_asset_val_config_wrk DEFAULT 1,
        submitted_by       NVARCHAR(100)  NULL,
        submitted_dt       DATETIME2      NULL,
        approved_by        NVARCHAR(100)  NULL,
        approved_dt        DATETIME2      NULL,
        activated_by       NVARCHAR(100)  NULL,
        activated_dt       DATETIME2      NULL,
        retired_dt         DATETIME2      NULL,
        record_version     ROWVERSION     NOT NULL,
        entered_by         NVARCHAR(100)  NOT NULL CONSTRAINT df_pm_asset_val_config_eby DEFAULT N'system',
        entered_dt         DATETIME2      NOT NULL CONSTRAINT df_pm_asset_val_config_edt DEFAULT SYSUTCDATETIME(),
        updated_by         NVARCHAR(100)  NULL,
        updated_dt         DATETIME2      NULL,
        CONSTRAINT uq_pm_asset_val_config_version UNIQUE (organization_id, version_no),
        CONSTRAINT ck_pm_asset_val_config_weights CHECK (weight_c BETWEEN 0 AND 100 AND weight_i BETWEEN 0 AND 100 AND weight_a BETWEEN 0 AND 100),
        CONSTRAINT ck_pm_asset_val_config_dates CHECK (effective_to IS NULL OR effective_from IS NULL OR effective_to >= effective_from),
        CONSTRAINT ck_pm_asset_val_config_flags CHECK (NOT (is_active_version = 1 AND is_working_version = 1))
    );
    CREATE UNIQUE INDEX ux_pm_asset_val_config_one_active
        ON grac_practice.asset_valuation_config(organization_id) WHERE is_active_version = 1;
    CREATE UNIQUE INDEX ux_pm_asset_val_config_one_working
        ON grac_practice.asset_valuation_config(organization_id) WHERE is_working_version = 1;
    PRINT '422: asset_valuation_config created.';
END
GO

IF OBJECT_ID('grac_practice.asset_cia_scale_level','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_cia_scale_level (
        level_id           BIGINT         IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_asset_cia_level PRIMARY KEY,
        config_id          BIGINT         NOT NULL
            CONSTRAINT fk_pm_asset_cia_level_config REFERENCES grac_practice.asset_valuation_config(config_id),
        dimension_code     NCHAR(1)       NOT NULL
            CONSTRAINT ck_pm_asset_cia_level_dim CHECK (dimension_code IN (N'C', N'I', N'A')),
        score              INT            NOT NULL,
        level_label        NVARCHAR(100)  NOT NULL,
        impact_description NVARCHAR(500)  NULL,
        display_order      INT            NOT NULL CONSTRAINT df_pm_asset_cia_level_order DEFAULT 0,
        entered_by         NVARCHAR(100)  NOT NULL CONSTRAINT df_pm_asset_cia_level_eby DEFAULT N'system',
        entered_dt         DATETIME2      NOT NULL CONSTRAINT df_pm_asset_cia_level_edt DEFAULT SYSUTCDATETIME(),
        updated_by         NVARCHAR(100)  NULL,
        updated_dt         DATETIME2      NULL,
        CONSTRAINT uq_pm_asset_cia_level UNIQUE (config_id, dimension_code, score)
    );
    PRINT '422: asset_cia_scale_level created.';
END
GO

IF OBJECT_ID('grac_practice.asset_value_band','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_value_band (
        band_id            BIGINT         IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_asset_value_band PRIMARY KEY,
        config_id          BIGINT         NOT NULL
            CONSTRAINT fk_pm_asset_value_band_config REFERENCES grac_practice.asset_valuation_config(config_id),
        min_score          DECIMAL(9, 4)  NOT NULL,
        max_score          DECIMAL(9, 4)  NOT NULL,
        category_label     NVARCHAR(100)  NOT NULL,
        treatment_guidance NVARCHAR(500)  NULL,
        display_order      INT            NOT NULL CONSTRAINT df_pm_asset_value_band_order DEFAULT 0,
        entered_by         NVARCHAR(100)  NOT NULL CONSTRAINT df_pm_asset_value_band_eby DEFAULT N'system',
        entered_dt         DATETIME2      NOT NULL CONSTRAINT df_pm_asset_value_band_edt DEFAULT SYSUTCDATETIME(),
        updated_by         NVARCHAR(100)  NULL,
        updated_dt         DATETIME2      NULL,
        CONSTRAINT ck_pm_asset_value_band_range CHECK (max_score >= min_score)
    );
    CREATE INDEX ix_pm_asset_value_band_config ON grac_practice.asset_value_band(config_id, min_score);
    PRINT '422: asset_value_band created.';
END
GO

IF OBJECT_ID('grac_practice.asset_criticality_level','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_criticality_level (
        level_id                BIGINT         IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_asset_crit_level PRIMARY KEY,
        config_id               BIGINT         NOT NULL
            CONSTRAINT fk_pm_asset_crit_level_config REFERENCES grac_practice.asset_valuation_config(config_id),
        score                   INT            NOT NULL,
        level_label             NVARCHAR(100)  NOT NULL,
        impact_description      NVARCHAR(500)  NULL,
        review_frequency_months INT            NULL
            CONSTRAINT ck_pm_asset_crit_level_review CHECK (review_frequency_months IS NULL OR review_frequency_months > 0),
        criticality_master_id   INT            NULL
            CONSTRAINT fk_pm_asset_crit_level_master REFERENCES grac_practice.criticality_master(criticality_id),
        display_order           INT            NOT NULL CONSTRAINT df_pm_asset_crit_level_order DEFAULT 0,
        entered_by              NVARCHAR(100)  NOT NULL CONSTRAINT df_pm_asset_crit_level_eby DEFAULT N'system',
        entered_dt              DATETIME2      NOT NULL CONSTRAINT df_pm_asset_crit_level_edt DEFAULT SYSUTCDATETIME(),
        updated_by              NVARCHAR(100)  NULL,
        updated_dt              DATETIME2      NULL,
        CONSTRAINT uq_pm_asset_crit_level UNIQUE (config_id, score)
    );
    PRINT '422: asset_criticality_level created.';
END
GO

-- =====================================================================
-- 2. Lifecycle (state-machine framework)
-- =====================================================================
MERGE grac_practice.entity_status_master AS t
USING (VALUES
    (N'AssetValuationConfig', N'DRAFT',            N'Draft',            10, 0, 1, N'Editable configuration; not used for calculation.'),
    (N'AssetValuationConfig', N'PENDING_APPROVAL', N'Pending Approval', 20, 0, 0, N'Submitted for review and approval.'),
    (N'AssetValuationConfig', N'APPROVED',         N'Approved',         30, 0, 0, N'Approved; ready for activation.'),
    (N'AssetValuationConfig', N'ACTIVE',           N'Active',           40, 0, 0, N'The configuration used for asset valuation; immutable.'),
    (N'AssetValuationConfig', N'RETIRED',          N'Retired',          50, 1, 0, N'Kept for history and past calculations.')
) AS s(entity_type, status_code, status_name, display_order, is_terminal, is_initial, description)
ON t.entity_type = s.entity_type AND t.status_code = s.status_code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (entity_type, status_code, status_name, display_order, is_terminal, is_initial, description, entered_by)
    VALUES (s.entity_type, s.status_code, s.status_name, s.display_order, s.is_terminal, s.is_initial, s.description, N'seed-422');
PRINT CONCAT('422: AssetValuationConfig statuses inserted: ', @@ROWCOUNT);
GO

MERGE grac_practice.entity_state_transition_rule AS t
USING (VALUES
    (CAST(NULL AS NVARCHAR(60)), N'DRAFT',     0, 0, N'Create a draft version.'),
    (N'DRAFT',            N'PENDING_APPROVAL', 0, 0, N'Submit for review and approval.'),
    (N'DRAFT',            N'RETIRED',          1, 0, N'Discard a draft.'),
    (N'PENDING_APPROVAL', N'APPROVED',         0, 1, N'Approve the version.'),
    (N'PENDING_APPROVAL', N'DRAFT',            1, 0, N'Return or reject to draft.'),
    (N'APPROVED',         N'ACTIVE',           0, 0, N'Activate for asset valuation.'),
    (N'APPROVED',         N'RETIRED',          1, 0, N'Withdraw an approved version.'),
    (N'ACTIVE',           N'RETIRED',          1, 0, N'Retire, or superseded by a newer active version.')
) AS s(from_status_code, to_status_code, requires_reason, requires_approval, description)
ON t.entity_type = N'AssetValuationConfig'
   AND ISNULL(t.from_status_code, N'__NULL__') = ISNULL(s.from_status_code, N'__NULL__')
   AND t.to_status_code = s.to_status_code
   AND t.actor_role_code IS NULL
WHEN NOT MATCHED BY TARGET THEN
    INSERT (entity_type, from_status_code, to_status_code, actor_role_code, requires_reason, requires_approval, description, entered_by)
    VALUES (N'AssetValuationConfig', s.from_status_code, s.to_status_code, NULL, s.requires_reason, s.requires_approval, s.description, N'seed-422');
PRINT CONCAT('422: AssetValuationConfig transition rules inserted: ', @@ROWCOUNT);
GO

-- =====================================================================
-- 3. Calculation (inline, so set-based callers can CROSS APPLY it)
-- =====================================================================
CREATE OR ALTER FUNCTION grac_practice.fn_asset_value_calc
(
    @config_id BIGINT,
    @c         INT,
    @i         INT,
    @a         INT
)
RETURNS TABLE
AS
RETURN
    SELECT x.raw_score AS RawScore, r.score AS AssetValueScore, b.category_label AS AssetValueCategory, b.band_id AS BandId
      FROM grac_practice.asset_valuation_config cfg
     CROSS APPLY (SELECT CAST(CASE cfg.valuation_method
                    WHEN N'MAXIMUM'          THEN (SELECT MAX(v) FROM (VALUES (@c), (@i), (@a)) t(v))
                    WHEN N'SUMMATION'        THEN @c + @i + @a
                    ELSE (@c * cfg.weight_c + @i * cfg.weight_i + @a * cfg.weight_a) / 100.0
                  END AS DECIMAL(18, 6)) AS raw_score) x
     CROSS APPLY (SELECT CAST(CASE cfg.rounding_mode
                    WHEN N'ROUND_DOWN' THEN ROUND(x.raw_score, cfg.decimal_places, 1)
                    WHEN N'ROUND_UP'   THEN CEILING(x.raw_score * POWER(10.0, cfg.decimal_places)) / POWER(10.0, cfg.decimal_places)
                    ELSE ROUND(x.raw_score, cfg.decimal_places)
                  END AS DECIMAL(18, 4)) AS score) r
      OUTER APPLY (SELECT TOP (1) vb.band_id, vb.category_label
                     FROM grac_practice.asset_value_band vb
                    WHERE vb.config_id = cfg.config_id AND r.score BETWEEN vb.min_score AND vb.max_score
                    ORDER BY vb.min_score) b
     WHERE cfg.config_id = @config_id
       AND @c IS NOT NULL AND @i IS NOT NULL AND @a IS NOT NULL;
GO

-- =====================================================================
-- 4. Readers
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_valuation_config_list
    @organization_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT c.config_id AS ConfigId, c.config_name AS ConfigName, c.version_no AS VersionNo,
           s.status_code AS StatusCode, s.status_name AS StatusName, c.valuation_method AS ValuationMethod,
           c.effective_from AS EffectiveFrom, c.effective_to AS EffectiveTo,
           (SELECT COUNT(*) FROM grac_practice.asset_value_band b WHERE b.config_id = c.config_id) AS BandCount,
           COALESCE(c.updated_dt, c.entered_dt) AS LastChangedDt
      FROM grac_practice.asset_valuation_config c
      JOIN grac_practice.entity_status_master s ON s.entity_status_id = c.current_status_id
     WHERE c.organization_id = @organization_id
     ORDER BY c.version_no DESC;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_asset_valuation_config_get
    @organization_id BIGINT,
    @config_id       BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    -- 1. Header
    SELECT c.config_id AS ConfigId, c.organization_id AS OrganizationId, c.config_name AS ConfigName,
           c.version_no AS VersionNo, s.status_code AS StatusCode, s.status_name AS StatusName,
           c.valuation_method AS ValuationMethod, c.weight_c AS WeightC, c.weight_i AS WeightI, c.weight_a AS WeightA,
           c.decimal_places AS DecimalPlaces, c.rounding_mode AS RoundingMode, c.override_allowed AS OverrideAllowed,
           c.effective_from AS EffectiveFrom, c.effective_to AS EffectiveTo, c.change_reason AS ChangeReason,
           src.version_no AS SourceVersionNo,
           c.submitted_by AS SubmittedBy, c.submitted_dt AS SubmittedDt, c.approved_by AS ApprovedBy, c.approved_dt AS ApprovedDt,
           c.activated_by AS ActivatedBy, c.activated_dt AS ActivatedDt, c.retired_dt AS RetiredDt,
           CONVERT(BIGINT, c.record_version) AS RecordVersion
      FROM grac_practice.asset_valuation_config c
      JOIN grac_practice.entity_status_master s ON s.entity_status_id = c.current_status_id
      LEFT JOIN grac_practice.asset_valuation_config src ON src.config_id = c.source_config_id
     WHERE c.config_id = @config_id AND c.organization_id = @organization_id;

    -- 2. CIA levels
    SELECT l.level_id AS LevelId, l.dimension_code AS DimensionCode, l.score AS Score, l.level_label AS LevelLabel,
           l.impact_description AS ImpactDescription, l.display_order AS DisplayOrder
      FROM grac_practice.asset_cia_scale_level l
      JOIN grac_practice.asset_valuation_config c ON c.config_id = l.config_id
     WHERE l.config_id = @config_id AND c.organization_id = @organization_id
     ORDER BY CASE l.dimension_code WHEN N'C' THEN 1 WHEN N'I' THEN 2 ELSE 3 END, l.score;

    -- 3. Value bands
    SELECT b.band_id AS BandId, b.min_score AS MinScore, b.max_score AS MaxScore, b.category_label AS CategoryLabel,
           b.treatment_guidance AS TreatmentGuidance, b.display_order AS DisplayOrder
      FROM grac_practice.asset_value_band b
      JOIN grac_practice.asset_valuation_config c ON c.config_id = b.config_id
     WHERE b.config_id = @config_id AND c.organization_id = @organization_id
     ORDER BY b.min_score;

    -- 4. Criticality levels
    SELECT l.level_id AS LevelId, l.score AS Score, l.level_label AS LevelLabel, l.impact_description AS ImpactDescription,
           l.review_frequency_months AS ReviewFrequencyMonths, l.criticality_master_id AS CriticalityMasterId,
           m.criticality_name AS CriticalityMasterName, l.display_order AS DisplayOrder
      FROM grac_practice.asset_criticality_level l
      JOIN grac_practice.asset_valuation_config c ON c.config_id = l.config_id
      LEFT JOIN grac_practice.criticality_master m ON m.criticality_id = l.criticality_master_id
     WHERE l.config_id = @config_id AND c.organization_id = @organization_id
     ORDER BY l.score;

    -- 5. History
    SELECT l.transition_log_id AS TransitionLogId, fs.status_name AS FromStatus, ts.status_name AS ToStatus,
           l.actor_employee_id AS ActorEmployeeId, e.employee_name AS ActorName,
           l.reason_code AS ReasonCode, l.reason_text AS ReasonText, l.transitioned_at AS TransitionedAt
      FROM grac_practice.entity_state_transition_log l
      JOIN grac_practice.asset_valuation_config c ON c.config_id = l.entity_id
      LEFT JOIN grac_practice.entity_status_master fs ON fs.entity_status_id = l.from_status_id
      JOIN grac_practice.entity_status_master ts ON ts.entity_status_id = l.to_status_id
      LEFT JOIN grac_practice.organization_employee e ON e.employee_id = l.actor_employee_id
     WHERE l.entity_type = N'AssetValuationConfig' AND l.entity_id = @config_id AND c.organization_id = @organization_id
     ORDER BY l.transitioned_at DESC, l.transition_log_id DESC;

    -- 6. Criticality master rows (mapping picker)
    SELECT criticality_id AS CriticalityId, criticality_name AS CriticalityName
      FROM grac_practice.criticality_master WHERE is_active = 1 ORDER BY display_order, criticality_name;
END
GO

-- =====================================================================
-- 5. Readiness (5.1.18.5.9). Callers wanting only the count pass
--    @suppress_result = 1 (never INSERT ... EXEC).
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_valuation_config_readiness
    @organization_id   BIGINT,
    @config_id         BIGINT,
    @suppress_result   BIT = 0,
    @out_error_count   INT = NULL OUTPUT,
    @out_warning_count INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @issues TABLE (check_code NVARCHAR(60) NOT NULL, severity NVARCHAR(10) NOT NULL, message NVARCHAR(400) NOT NULL);

    DECLARE @method NVARCHAR(30), @wc DECIMAL(5, 2), @wi DECIMAL(5, 2), @wa DECIMAL(5, 2), @dp TINYINT, @version INT, @reason NVARCHAR(1000);
    SELECT @method = valuation_method, @wc = weight_c, @wi = weight_i, @wa = weight_a, @dp = decimal_places,
           @version = version_no, @reason = change_reason
      FROM grac_practice.asset_valuation_config WHERE config_id = @config_id AND organization_id = @organization_id;
    IF @method IS NULL THROW 54251, 'Valuation configuration not found for this organization.', 1;

    -- Dimensions: at least two levels each.
    INSERT @issues (check_code, severity, message)
    SELECT N'DIMENSION_LEVELS', N'ERROR',
           CONCAT(CASE d.code WHEN N'C' THEN N'Confidentiality' WHEN N'I' THEN N'Integrity' ELSE N'Availability' END,
                  N' needs at least two scale levels.')
      FROM (VALUES (N'C'), (N'I'), (N'A')) d(code)
     WHERE (SELECT COUNT(*) FROM grac_practice.asset_cia_scale_level l
             WHERE l.config_id = @config_id AND l.dimension_code = d.code) < 2;

    IF @method = N'WEIGHTED_AVERAGE' AND @wc + @wi + @wa <> 100
        INSERT @issues (check_code, severity, message)
        VALUES (N'WEIGHTS_TOTAL', N'ERROR', CONCAT(N'Weighted Average weights must total 100 percent (now ',
                CAST(@wc + @wi + @wa AS NVARCHAR(20)), N').'));

    IF @version > 1 AND NULLIF(LTRIM(RTRIM(@reason)), N'') IS NULL
        INSERT @issues (check_code, severity, message) VALUES (N'REASON_MISSING', N'ERROR', N'Change reason is required for a new version.');

    IF NOT EXISTS (SELECT 1 FROM grac_practice.asset_criticality_level WHERE config_id = @config_id)
        INSERT @issues (check_code, severity, message) VALUES (N'CRITICALITY_EMPTY', N'ERROR', N'The criticality scale needs at least one level.');

    -- Possible score range for the method.
    DECLARE @minC INT, @maxC INT, @minI INT, @maxI INT, @minA INT, @maxA INT;
    SELECT @minC = MIN(score), @maxC = MAX(score) FROM grac_practice.asset_cia_scale_level WHERE config_id = @config_id AND dimension_code = N'C';
    SELECT @minI = MIN(score), @maxI = MAX(score) FROM grac_practice.asset_cia_scale_level WHERE config_id = @config_id AND dimension_code = N'I';
    SELECT @minA = MIN(score), @maxA = MAX(score) FROM grac_practice.asset_cia_scale_level WHERE config_id = @config_id AND dimension_code = N'A';

    DECLARE @range_min DECIMAL(18, 4), @range_max DECIMAL(18, 4);
    IF @minC IS NOT NULL AND @minI IS NOT NULL AND @minA IS NOT NULL
    BEGIN
        IF @method = N'SUMMATION'
            SELECT @range_min = @minC + @minI + @minA, @range_max = @maxC + @maxI + @maxA;
        ELSE IF @method = N'MAXIMUM'
            SELECT @range_min = (SELECT MAX(v) FROM (VALUES (@minC), (@minI), (@minA)) t(v)),
                   @range_max = (SELECT MAX(v) FROM (VALUES (@maxC), (@maxI), (@maxA)) t(v));
        ELSE
            SELECT @range_min = (@minC * @wc + @minI * @wi + @minA * @wa) / 100.0,
                   @range_max = (@maxC * @wc + @maxI * @wi + @maxA * @wa) / 100.0;
    END

    -- Bands: present, no overlap, no gap at the configured precision, full coverage.
    -- Maximum and Summation of integer scores are always whole numbers, so
    -- a band may end at 2 and the next start at 3; Weighted Average yields
    -- fractions, so the step is the configured precision.
    DECLARE @step DECIMAL(18, 4) = CASE WHEN @method IN (N'MAXIMUM', N'SUMMATION') THEN 1
                                        ELSE POWER(CAST(10 AS DECIMAL(18, 4)), -CAST(@dp AS INT)) END;
    DECLARE @bands TABLE (rn INT NOT NULL PRIMARY KEY, min_score DECIMAL(9, 4) NOT NULL, max_score DECIMAL(9, 4) NOT NULL, label NVARCHAR(100) NOT NULL);
    INSERT @bands (rn, min_score, max_score, label)
    SELECT ROW_NUMBER() OVER (ORDER BY min_score, max_score), min_score, max_score, category_label
      FROM grac_practice.asset_value_band WHERE config_id = @config_id;

    IF NOT EXISTS (SELECT 1 FROM @bands)
        INSERT @issues (check_code, severity, message)
        VALUES (N'BANDS_EMPTY', N'ERROR', N'Define the Asset Value bands (score range -> category). The BRD does not prescribe the ranges.');
    ELSE
    BEGIN
        INSERT @issues (check_code, severity, message)
        SELECT N'BAND_OVERLAP', N'ERROR', CONCAT(N'Bands "', a.label, N'" and "', b.label, N'" overlap.')
          FROM @bands a JOIN @bands b ON b.rn = a.rn + 1
         WHERE b.min_score <= a.max_score;

        INSERT @issues (check_code, severity, message)
        SELECT N'BAND_GAP', N'ERROR', CONCAT(N'Gap between "', a.label, N'" (to ', CAST(a.max_score AS NVARCHAR(20)),
               N') and "', b.label, N'" (from ', CAST(b.min_score AS NVARCHAR(20)), N').')
          FROM @bands a JOIN @bands b ON b.rn = a.rn + 1
         WHERE b.min_score > a.max_score + @step;

        IF @range_min IS NOT NULL
        BEGIN
            IF (SELECT MIN(min_score) FROM @bands) > @range_min
                INSERT @issues (check_code, severity, message)
                VALUES (N'BAND_COVERAGE', N'ERROR', CONCAT(N'The lowest possible score (', CAST(@range_min AS NVARCHAR(20)), N') has no band.'));
            IF (SELECT MAX(max_score) FROM @bands) < @range_max
                INSERT @issues (check_code, severity, message)
                VALUES (N'BAND_COVERAGE', N'ERROR', CONCAT(N'The highest possible score (', CAST(@range_max AS NVARCHAR(20)), N') has no band.'));
        END
    END

    IF EXISTS (SELECT 1 FROM grac_practice.asset_criticality_level WHERE config_id = @config_id AND criticality_master_id IS NULL)
        INSERT @issues (check_code, severity, message)
        VALUES (N'CRITICALITY_UNMAPPED', N'WARNING', N'Some criticality levels are not mapped to the existing Criticality values used on assets today.');

    SELECT @out_error_count = COUNT(CASE WHEN severity = N'ERROR' THEN 1 END),
           @out_warning_count = COUNT(CASE WHEN severity = N'WARNING' THEN 1 END)
      FROM @issues;

    IF ISNULL(@suppress_result, 0) = 1 RETURN;
    SELECT check_code AS CheckCode, severity AS Severity, message AS Message,
           @range_min AS RangeMin, @range_max AS RangeMax
      FROM @issues ORDER BY CASE severity WHEN N'ERROR' THEN 0 ELSE 1 END, check_code;
END
GO

-- =====================================================================
-- 6. Writers
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_valuation_config_assert_editable
    @organization_id         BIGINT,
    @config_id               BIGINT,
    @expected_record_version BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @status NVARCHAR(60), @rv BIGINT;
    SELECT @status = s.status_code, @rv = CONVERT(BIGINT, c.record_version)
      FROM grac_practice.asset_valuation_config c
      JOIN grac_practice.entity_status_master s ON s.entity_status_id = c.current_status_id
     WHERE c.config_id = @config_id AND c.organization_id = @organization_id;
    IF @status IS NULL THROW 54251, 'Valuation configuration not found for this organization.', 1;
    IF @status <> N'DRAFT'
        THROW 54252, 'Only a Draft configuration can be changed. An Active version is immutable; create a new version.', 1;
    IF @expected_record_version IS NOT NULL AND @expected_record_version <> @rv
        THROW 54253, 'This configuration was changed by someone else. Reload it and try again.', 1;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_asset_valuation_config_create
    @organization_id   BIGINT,
    @config_name       NVARCHAR(200) = NULL,
    @source_config_id  BIGINT        = NULL,
    @change_reason     NVARCHAR(1000) = NULL,
    @actor_employee_id BIGINT        = NULL,
    @actor             NVARCHAR(100) = N'system',
    @out_config_id     BIGINT        = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    SET @change_reason = NULLIF(LTRIM(RTRIM(@change_reason)), N'');
    SET @config_name = NULLIF(LTRIM(RTRIM(@config_name)), N'');

    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 54250, 'Organization not found.', 1;
    IF @source_config_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM grac_practice.asset_valuation_config WHERE config_id = @source_config_id AND organization_id = @organization_id)
        THROW 54251, 'Valuation configuration not found for this organization.', 1;

    DECLARE @working INT = (SELECT version_no FROM grac_practice.asset_valuation_config
                             WHERE organization_id = @organization_id AND is_working_version = 1);
    IF @working IS NOT NULL
    BEGIN
        DECLARE @msg_working NVARCHAR(300) = CONCAT(N'Version ', @working,
            N' is still being worked on (Draft, Pending Approval or Approved). Finish or retire it first.');
        THROW 54254, @msg_working, 1;
    END

    DECLARE @next INT = ISNULL((SELECT MAX(version_no) FROM grac_practice.asset_valuation_config
                                 WHERE organization_id = @organization_id), 0) + 1;
    IF @next > 1 AND @change_reason IS NULL
        THROW 54255, 'A change reason is required for a new version.', 1;

    DECLARE @draft_id INT = grac_practice.fn_get_entity_status_id(N'AssetValuationConfig', N'DRAFT');
    DECLARE @to_status_id INT, @log_id BIGINT;
    DECLARE @src BIGINT = @source_config_id;
    IF @src IS NULL AND @next > 1
        SET @src = (SELECT TOP (1) config_id FROM grac_practice.asset_valuation_config
                     WHERE organization_id = @organization_id ORDER BY is_active_version DESC, version_no DESC);

    BEGIN TRAN;

    IF @src IS NULL
        INSERT grac_practice.asset_valuation_config
            (organization_id, config_name, version_no, current_status_id, change_reason, is_active_version, is_working_version, entered_by)
        VALUES (@organization_id, ISNULL(@config_name, N'Asset valuation'), @next, @draft_id, @change_reason, 0, 1, @actor);
    ELSE
        INSERT grac_practice.asset_valuation_config
            (organization_id, config_name, version_no, current_status_id, valuation_method, weight_c, weight_i, weight_a,
             decimal_places, rounding_mode, override_allowed, change_reason, source_config_id, is_active_version, is_working_version, entered_by)
        SELECT organization_id, ISNULL(@config_name, config_name), @next, @draft_id, valuation_method, weight_c, weight_i, weight_a,
               decimal_places, rounding_mode, override_allowed, @change_reason, config_id, 0, 1, @actor
          FROM grac_practice.asset_valuation_config WHERE config_id = @src;
    SET @out_config_id = SCOPE_IDENTITY();

    EXEC grac_practice.sp_pm_state_transition
         @entity_type = N'AssetValuationConfig', @entity_id = @out_config_id,
         @from_status_code = NULL, @to_status_code = N'DRAFT',
         @actor_employee_id = @actor_employee_id, @actor_role_code = NULL,
         @reason_code = N'CREATED', @reason_text = @change_reason,
         @to_status_id = @to_status_id OUTPUT, @transition_log_id = @log_id OUTPUT;

    IF @src IS NULL
    BEGIN
        -- BRD 5.1.18 default 1-5 scale, the same for C, I and A.
        INSERT grac_practice.asset_cia_scale_level (config_id, dimension_code, score, level_label, impact_description, display_order, entered_by)
        SELECT @out_config_id, d.code, s.score, s.label, s.impact, s.score * 10, @actor
          FROM (VALUES (N'C'), (N'I'), (N'A')) d(code)
         CROSS JOIN (VALUES
            (1, N'Negligible', N'Very minor loss; no operational, financial, or legal impact.'),
            (2, N'Low',        N'Minor operational delay; low financial cost; no regulatory breach.'),
            (3, N'Medium',     N'Moderate impact; noticeable operational disruption; minor breach/fine.'),
            (4, N'High',       N'Significant financial loss; major operational stoppage; regulatory violation.'),
            (5, N'Critical',   N'Severe harm to business survival; catastrophic financial or legal penalty.')
         ) s(score, label, impact);

        -- The criticality values assets use today, one level each.
        INSERT grac_practice.asset_criticality_level (config_id, score, level_label, criticality_master_id, display_order, entered_by)
        SELECT @out_config_id, ROW_NUMBER() OVER (ORDER BY m.display_order, m.criticality_id),
               m.criticality_name, m.criticality_id,
               ROW_NUMBER() OVER (ORDER BY m.display_order, m.criticality_id) * 10, @actor
          FROM grac_practice.criticality_master m WHERE m.is_active = 1;
    END
    ELSE
    BEGIN
        INSERT grac_practice.asset_cia_scale_level (config_id, dimension_code, score, level_label, impact_description, display_order, entered_by)
        SELECT @out_config_id, dimension_code, score, level_label, impact_description, display_order, @actor
          FROM grac_practice.asset_cia_scale_level WHERE config_id = @src;
        INSERT grac_practice.asset_value_band (config_id, min_score, max_score, category_label, treatment_guidance, display_order, entered_by)
        SELECT @out_config_id, min_score, max_score, category_label, treatment_guidance, display_order, @actor
          FROM grac_practice.asset_value_band WHERE config_id = @src;
        INSERT grac_practice.asset_criticality_level
            (config_id, score, level_label, impact_description, review_frequency_months, criticality_master_id, display_order, entered_by)
        SELECT @out_config_id, score, level_label, impact_description, review_frequency_months, criticality_master_id, display_order, @actor
          FROM grac_practice.asset_criticality_level WHERE config_id = @src;
    END

    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, after_json, status, entered_by)
    VALUES (N'asset-valuation-config', @out_config_id, N'CREATE',
            (SELECT @organization_id AS organizationId, @next AS versionNo, @src AS sourceConfigId, @change_reason AS changeReason
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER), N'Active', @actor);
    COMMIT;

    SELECT @out_config_id AS ConfigId;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_asset_valuation_config_header_save
    @organization_id         BIGINT,
    @config_id               BIGINT,
    @config_name             NVARCHAR(200),
    @valuation_method        NVARCHAR(30),
    @weight_c                DECIMAL(5, 2),
    @weight_i                DECIMAL(5, 2),
    @weight_a                DECIMAL(5, 2),
    @decimal_places          TINYINT,
    @rounding_mode           NVARCHAR(20),
    @override_allowed        BIT            = 0,
    @effective_from          DATE           = NULL,
    @effective_to            DATE           = NULL,
    @change_reason           NVARCHAR(1000) = NULL,
    @expected_record_version BIGINT         = NULL,
    @actor                   NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    SET @valuation_method = UPPER(LTRIM(RTRIM(ISNULL(@valuation_method, N''))));
    SET @rounding_mode = UPPER(LTRIM(RTRIM(ISNULL(@rounding_mode, N''))));
    SET @config_name = NULLIF(LTRIM(RTRIM(@config_name)), N'');

    EXEC grac_practice.sp_asset_valuation_config_assert_editable
         @organization_id = @organization_id, @config_id = @config_id, @expected_record_version = @expected_record_version;

    IF @config_name IS NULL THROW 54259, 'Configuration name is required.', 1;
    IF @valuation_method NOT IN (N'MAXIMUM', N'WEIGHTED_AVERAGE', N'SUMMATION')
        THROW 54256, 'Valuation method must be Maximum, Weighted Average or Summation.', 1;
    IF @rounding_mode NOT IN (N'ROUND_HALF_UP', N'ROUND_DOWN', N'ROUND_UP')
        THROW 54256, 'Rounding must be half-up, down or up.', 1;
    IF ISNULL(@weight_c, -1) NOT BETWEEN 0 AND 100 OR ISNULL(@weight_i, -1) NOT BETWEEN 0 AND 100 OR ISNULL(@weight_a, -1) NOT BETWEEN 0 AND 100
        THROW 54257, 'Each weight must be between 0 and 100.', 1;
    IF ISNULL(@decimal_places, 255) > 4 THROW 54269, 'Decimal places must be between 0 and 4.', 1;
    IF @effective_from IS NOT NULL AND @effective_to IS NOT NULL AND @effective_to < @effective_from
        THROW 54261, 'Effective To cannot be before Effective From.', 1;

    DECLARE @before NVARCHAR(MAX) = (
        SELECT config_name AS configName, valuation_method AS valuationMethod, weight_c AS weightC, weight_i AS weightI,
               weight_a AS weightA, decimal_places AS decimalPlaces, rounding_mode AS roundingMode,
               override_allowed AS overrideAllowed, effective_from AS effectiveFrom, effective_to AS effectiveTo,
               change_reason AS changeReason
          FROM grac_practice.asset_valuation_config WHERE config_id = @config_id FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    BEGIN TRAN;
    UPDATE grac_practice.asset_valuation_config
       SET config_name = @config_name, valuation_method = @valuation_method,
           weight_c = @weight_c, weight_i = @weight_i, weight_a = @weight_a,
           decimal_places = @decimal_places, rounding_mode = @rounding_mode,
           override_allowed = ISNULL(@override_allowed, 0),
           effective_from = @effective_from, effective_to = @effective_to,
           change_reason = NULLIF(LTRIM(RTRIM(@change_reason)), N''),
           updated_by = @actor, updated_dt = SYSUTCDATETIME()
     WHERE config_id = @config_id;
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-valuation-config', @config_id, N'HEADER_SAVE', @before,
            (SELECT @config_name AS configName, @valuation_method AS valuationMethod, @weight_c AS weightC, @weight_i AS weightI,
                    @weight_a AS weightA, @decimal_places AS decimalPlaces, @rounding_mode AS roundingMode,
                    @override_allowed AS overrideAllowed, @effective_from AS effectiveFrom, @effective_to AS effectiveTo,
                    @change_reason AS changeReason FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            N'Active', @actor);
    COMMIT;
END
GO

-- One item writer for the three child lists (CIA level, value band,
-- criticality level): @item_kind picks the list; @item_id NULL adds,
-- otherwise updates; @remove = 1 deletes.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_valuation_config_item_save
    @organization_id         BIGINT,
    @config_id               BIGINT,
    @item_kind               NVARCHAR(20),
    @item_id                 BIGINT         = NULL,
    @remove                  BIT            = 0,
    @dimension_code          NCHAR(1)       = NULL,
    @score                   INT            = NULL,
    @min_score               DECIMAL(9, 4)  = NULL,
    @max_score               DECIMAL(9, 4)  = NULL,
    @label                   NVARCHAR(100)  = NULL,
    @description             NVARCHAR(500)  = NULL,
    @review_frequency_months INT            = NULL,
    @criticality_master_id   INT            = NULL,
    @display_order           INT            = NULL,
    @actor                   NVARCHAR(100)  = N'system',
    @out_item_id             BIGINT         = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    SET @item_kind = UPPER(LTRIM(RTRIM(ISNULL(@item_kind, N''))));
    SET @label = NULLIF(LTRIM(RTRIM(@label)), N'');
    SET @description = NULLIF(LTRIM(RTRIM(@description)), N'');
    SET @dimension_code = UPPER(@dimension_code);
    SET @remove = ISNULL(@remove, 0);

    EXEC grac_practice.sp_asset_valuation_config_assert_editable
         @organization_id = @organization_id, @config_id = @config_id;

    IF @item_kind NOT IN (N'CIA_LEVEL', N'BAND', N'CRITICALITY')
        THROW 54256, 'Unknown configuration list.', 1;

    IF @item_id IS NOT NULL AND NOT (
           (@item_kind = N'CIA_LEVEL'   AND EXISTS (SELECT 1 FROM grac_practice.asset_cia_scale_level   WHERE level_id = @item_id AND config_id = @config_id))
        OR (@item_kind = N'BAND'        AND EXISTS (SELECT 1 FROM grac_practice.asset_value_band        WHERE band_id  = @item_id AND config_id = @config_id))
        OR (@item_kind = N'CRITICALITY' AND EXISTS (SELECT 1 FROM grac_practice.asset_criticality_level WHERE level_id = @item_id AND config_id = @config_id)))
        THROW 54268, 'Item not found on this configuration.', 1;

    IF @remove = 0
    BEGIN
        IF @label IS NULL THROW 54259, 'A label is required.', 1;
        IF @item_kind = N'CIA_LEVEL'
        BEGIN
            IF ISNULL(@dimension_code, N'') NOT IN (N'C', N'I', N'A') THROW 54258, 'Dimension must be Confidentiality, Integrity or Availability.', 1;
            IF @score IS NULL OR @score < 0 THROW 54259, 'A score of zero or more is required.', 1;
            IF EXISTS (SELECT 1 FROM grac_practice.asset_cia_scale_level
                        WHERE config_id = @config_id AND dimension_code = @dimension_code AND score = @score
                          AND (@item_id IS NULL OR level_id <> @item_id))
                THROW 54260, 'That score already exists for this dimension.', 1;
        END
        IF @item_kind = N'BAND'
        BEGIN
            IF @min_score IS NULL OR @max_score IS NULL OR @max_score < @min_score
                THROW 54261, 'Enter a minimum and a maximum score; the maximum cannot be below the minimum.', 1;
            IF EXISTS (SELECT 1 FROM grac_practice.asset_value_band
                        WHERE config_id = @config_id AND (@item_id IS NULL OR band_id <> @item_id)
                          AND @min_score <= max_score AND @max_score >= min_score)
                THROW 54262, 'This range overlaps another band.', 1;
        END
        IF @item_kind = N'CRITICALITY'
        BEGIN
            IF @score IS NULL OR @score < 0 THROW 54259, 'A score of zero or more is required.', 1;
            IF EXISTS (SELECT 1 FROM grac_practice.asset_criticality_level
                        WHERE config_id = @config_id AND score = @score AND (@item_id IS NULL OR level_id <> @item_id))
                THROW 54260, 'That criticality score already exists.', 1;
            IF @review_frequency_months IS NOT NULL AND @review_frequency_months <= 0
                THROW 54259, 'Review frequency must be a positive number of months.', 1;
            IF @criticality_master_id IS NOT NULL AND NOT EXISTS (
                SELECT 1 FROM grac_practice.criticality_master WHERE criticality_id = @criticality_master_id AND is_active = 1)
                THROW 54267, 'Map to an active Criticality value.', 1;
        END
    END

    BEGIN TRAN;
    IF @remove = 1
    BEGIN
        IF @item_kind = N'CIA_LEVEL'   DELETE grac_practice.asset_cia_scale_level   WHERE level_id = @item_id AND config_id = @config_id;
        IF @item_kind = N'BAND'        DELETE grac_practice.asset_value_band        WHERE band_id  = @item_id AND config_id = @config_id;
        IF @item_kind = N'CRITICALITY' DELETE grac_practice.asset_criticality_level WHERE level_id = @item_id AND config_id = @config_id;
        SET @out_item_id = @item_id;
    END
    ELSE IF @item_kind = N'CIA_LEVEL'
    BEGIN
        IF @item_id IS NULL
        BEGIN
            INSERT grac_practice.asset_cia_scale_level (config_id, dimension_code, score, level_label, impact_description, display_order, entered_by)
            VALUES (@config_id, @dimension_code, @score, @label, @description, ISNULL(@display_order, @score * 10), @actor);
            SET @out_item_id = SCOPE_IDENTITY();
        END
        ELSE
        BEGIN
            UPDATE grac_practice.asset_cia_scale_level
               SET dimension_code = @dimension_code, score = @score, level_label = @label, impact_description = @description,
                   display_order = ISNULL(@display_order, display_order), updated_by = @actor, updated_dt = SYSUTCDATETIME()
             WHERE level_id = @item_id;
            SET @out_item_id = @item_id;
        END
    END
    ELSE IF @item_kind = N'BAND'
    BEGIN
        IF @item_id IS NULL
        BEGIN
            INSERT grac_practice.asset_value_band (config_id, min_score, max_score, category_label, treatment_guidance, display_order, entered_by)
            VALUES (@config_id, @min_score, @max_score, @label, @description, ISNULL(@display_order, 0), @actor);
            SET @out_item_id = SCOPE_IDENTITY();
        END
        ELSE
        BEGIN
            UPDATE grac_practice.asset_value_band
               SET min_score = @min_score, max_score = @max_score, category_label = @label, treatment_guidance = @description,
                   display_order = ISNULL(@display_order, display_order), updated_by = @actor, updated_dt = SYSUTCDATETIME()
             WHERE band_id = @item_id;
            SET @out_item_id = @item_id;
        END
    END
    ELSE
    BEGIN
        IF @item_id IS NULL
        BEGIN
            INSERT grac_practice.asset_criticality_level
                (config_id, score, level_label, impact_description, review_frequency_months, criticality_master_id, display_order, entered_by)
            VALUES (@config_id, @score, @label, @description, @review_frequency_months, @criticality_master_id, ISNULL(@display_order, @score * 10), @actor);
            SET @out_item_id = SCOPE_IDENTITY();
        END
        ELSE
        BEGIN
            UPDATE grac_practice.asset_criticality_level
               SET score = @score, level_label = @label, impact_description = @description,
                   review_frequency_months = @review_frequency_months, criticality_master_id = @criticality_master_id,
                   display_order = ISNULL(@display_order, display_order), updated_by = @actor, updated_dt = SYSUTCDATETIME()
             WHERE level_id = @item_id;
            SET @out_item_id = @item_id;
        END
    END

    UPDATE grac_practice.asset_valuation_config SET updated_by = @actor, updated_dt = SYSUTCDATETIME()
     WHERE config_id = @config_id;

    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, after_json, status, entered_by)
    VALUES (N'asset-valuation-config', @config_id,
            CONCAT(@item_kind, CASE WHEN @remove = 1 THEN N'_REMOVE' WHEN @item_id IS NULL THEN N'_ADD' ELSE N'_SAVE' END),
            (SELECT @out_item_id AS itemId, @dimension_code AS dimensionCode, @score AS score, @min_score AS minScore,
                    @max_score AS maxScore, @label AS label, @description AS description,
                    @review_frequency_months AS reviewFrequencyMonths, @criticality_master_id AS criticalityMasterId
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            N'Active', @actor);
    COMMIT;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_asset_valuation_config_transition
    @organization_id         BIGINT,
    @config_id               BIGINT,
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
    SET @to_status_code = UPPER(LTRIM(RTRIM(ISNULL(@to_status_code, N''))));
    SET @reason_text = NULLIF(LTRIM(RTRIM(@reason_text)), N'');

    DECLARE @from NVARCHAR(60), @rv BIGINT, @submitted_by NVARCHAR(100), @effective_from DATE,
            @today DATE = CAST(SYSUTCDATETIME() AS DATE);
    SELECT @from = s.status_code, @rv = CONVERT(BIGINT, c.record_version), @submitted_by = c.submitted_by,
           @effective_from = c.effective_from
      FROM grac_practice.asset_valuation_config c
      JOIN grac_practice.entity_status_master s ON s.entity_status_id = c.current_status_id
     WHERE c.config_id = @config_id AND c.organization_id = @organization_id;
    IF @from IS NULL THROW 54251, 'Valuation configuration not found for this organization.', 1;
    IF @expected_record_version IS NOT NULL AND @expected_record_version <> @rv
        THROW 54253, 'This configuration was changed by someone else. Reload it and try again.', 1;
    IF @to_status_code IN (N'DRAFT', N'RETIRED') AND @reason_text IS NULL
        THROW 54265, 'A reason is required to return or retire a configuration version.', 1;

    IF @to_status_code IN (N'PENDING_APPROVAL', N'APPROVED', N'ACTIVE')
    BEGIN
        DECLARE @errors INT = 0, @warnings INT = 0;
        EXEC grac_practice.sp_asset_valuation_config_readiness
             @organization_id = @organization_id, @config_id = @config_id, @suppress_result = 1,
             @out_error_count = @errors OUTPUT, @out_warning_count = @warnings OUTPUT;
        IF @errors > 0
        BEGIN
            DECLARE @msg_ready NVARCHAR(300) = CONCAT(N'The configuration is not ready: ', @errors,
                N' blocking issue(s). Open the readiness checks and resolve them first.');
            THROW 54263, @msg_ready, 1;
        END
    END
    IF @from = N'PENDING_APPROVAL' AND @to_status_code = N'APPROVED' AND @submitted_by = @actor
        THROW 54264, 'Segregation of duties: the person who submitted this version cannot approve it.', 1;
    IF @to_status_code = N'ACTIVE' AND @effective_from IS NOT NULL AND @effective_from > @today
        THROW 54266, 'Effective From is in the future. Activation is immediate; clear the date or set it to today or earlier.', 1;

    DECLARE @reason_code NVARCHAR(60) = CASE @to_status_code
        WHEN N'DRAFT' THEN N'RETURNED' WHEN N'RETIRED' THEN N'RETIRED' WHEN N'PENDING_APPROVAL' THEN N'SUBMITTED'
        WHEN N'APPROVED' THEN N'APPROVED' WHEN N'ACTIVE' THEN N'ACTIVATED' ELSE NULL END;
    DECLARE @to_status_id INT, @log_id BIGINT, @prev_id BIGINT, @prev_from DATE, @retired_id INT, @prev_log BIGINT;

    BEGIN TRAN;
    EXEC grac_practice.sp_pm_state_transition
         @entity_type = N'AssetValuationConfig', @entity_id = @config_id,
         @from_status_code = @from, @to_status_code = @to_status_code,
         @actor_employee_id = @actor_employee_id, @actor_role_code = NULL,
         @reason_code = @reason_code, @reason_text = @reason_text,
         @to_status_id = @to_status_id OUTPUT, @transition_log_id = @log_id OUTPUT;

    IF @to_status_code = N'ACTIVE'
    BEGIN
        SET @effective_from = ISNULL(@effective_from, @today);
        SELECT @prev_id = config_id, @prev_from = effective_from
          FROM grac_practice.asset_valuation_config
         WHERE organization_id = @organization_id AND is_active_version = 1 AND config_id <> @config_id;
        IF @prev_id IS NOT NULL
        BEGIN
            DECLARE @supersede NVARCHAR(1000) = CONCAT(N'Superseded by configuration #', @config_id, N'.');
            EXEC grac_practice.sp_pm_state_transition
                 @entity_type = N'AssetValuationConfig', @entity_id = @prev_id,
                 @from_status_code = N'ACTIVE', @to_status_code = N'RETIRED',
                 @actor_employee_id = @actor_employee_id, @actor_role_code = NULL,
                 @reason_code = N'SUPERSEDED', @reason_text = @supersede,
                 @to_status_id = @retired_id OUTPUT, @transition_log_id = @prev_log OUTPUT;
            UPDATE grac_practice.asset_valuation_config
               SET current_status_id = @retired_id, is_active_version = 0, is_working_version = 0,
                   effective_to = CASE WHEN DATEADD(DAY, -1, @effective_from) < ISNULL(@prev_from, @effective_from)
                                       THEN ISNULL(@prev_from, @effective_from) ELSE DATEADD(DAY, -1, @effective_from) END,
                   retired_dt = SYSUTCDATETIME(), updated_by = @actor, updated_dt = SYSUTCDATETIME()
             WHERE config_id = @prev_id;
        END
        UPDATE grac_practice.asset_valuation_config
           SET current_status_id = @to_status_id, is_working_version = 0, is_active_version = 1,
               effective_from = @effective_from, activated_by = @actor, activated_dt = SYSUTCDATETIME(),
               updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE config_id = @config_id;
    END
    ELSE IF @to_status_code = N'RETIRED'
        UPDATE grac_practice.asset_valuation_config
           SET current_status_id = @to_status_id, is_working_version = 0, is_active_version = 0,
               effective_to = CASE WHEN @from = N'ACTIVE' THEN ISNULL(effective_to, @today) ELSE effective_to END,
               retired_dt = SYSUTCDATETIME(), updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE config_id = @config_id;
    ELSE
        UPDATE grac_practice.asset_valuation_config
           SET current_status_id = @to_status_id, is_working_version = 1, is_active_version = 0,
               submitted_by = CASE WHEN @to_status_code = N'PENDING_APPROVAL' THEN @actor WHEN @to_status_code = N'DRAFT' THEN NULL ELSE submitted_by END,
               submitted_dt = CASE WHEN @to_status_code = N'PENDING_APPROVAL' THEN SYSUTCDATETIME() WHEN @to_status_code = N'DRAFT' THEN NULL ELSE submitted_dt END,
               approved_by  = CASE WHEN @to_status_code = N'APPROVED' THEN @actor WHEN @to_status_code = N'DRAFT' THEN NULL ELSE approved_by END,
               approved_dt  = CASE WHEN @to_status_code = N'APPROVED' THEN SYSUTCDATETIME() WHEN @to_status_code = N'DRAFT' THEN NULL ELSE approved_dt END,
               updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE config_id = @config_id;
    COMMIT;

    SELECT @config_id AS ConfigId, @to_status_code AS StatusCode, @prev_id AS SupersededConfigId;
END
GO

-- Calculator (read-only): any version of the organization's configuration.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_valuation_calculate
    @organization_id BIGINT,
    @config_id       BIGINT,
    @confidentiality INT,
    @integrity       INT,
    @availability    INT
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.asset_valuation_config WHERE config_id = @config_id AND organization_id = @organization_id)
        THROW 54251, 'Valuation configuration not found for this organization.', 1;
    SELECT f.RawScore, f.AssetValueScore, f.AssetValueCategory, f.BandId,
           CASE WHEN f.AssetValueCategory IS NULL THEN N'No band covers this score.' END AS ValidationMessage
      FROM grac_practice.fn_asset_value_calc(@config_id, @confidentiality, @integrity, @availability) f;
END
GO

-- =====================================================================
-- 7. Re-issued from 421: template option lists include the Active CIA
--    scale; readiness stops warning once one is Active. Otherwise the
--    421 bodies, unchanged.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_form_template_get
    @organization_id BIGINT,
    @template_id     BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    -- 1. Header (empty when the template is not this organization's).
    SELECT t.template_id AS TemplateId, t.organization_id AS OrganizationId,
           t.asset_type_id AS AssetTypeId, at.asset_type_name AS AssetTypeName,
           sc.subcategory_name AS SubcategoryName, ac.asset_category_name AS CategoryName,
           t.template_name AS TemplateName, t.version_no AS VersionNo,
           s.status_code AS StatusCode, s.status_name AS StatusName,
           t.approval_required AS ApprovalRequired,
           t.template_owner_employee_id AS TemplateOwnerEmployeeId, o.employee_name AS TemplateOwnerName,
           t.effective_from AS EffectiveFrom, t.effective_to AS EffectiveTo,
           t.change_reason AS ChangeReason, t.source_template_id AS SourceTemplateId,
           src.version_no AS SourceVersionNo,
           t.submitted_by AS SubmittedBy, t.submitted_dt AS SubmittedDt,
           t.approved_by AS ApprovedBy, t.approved_dt AS ApprovedDt,
           t.activated_by AS ActivatedBy, t.activated_dt AS ActivatedDt, t.retired_dt AS RetiredDt,
           CONVERT(BIGINT, t.record_version) AS RecordVersion,
           t.entered_by AS EnteredBy, t.entered_dt AS EnteredDt, t.updated_by AS UpdatedBy, t.updated_dt AS UpdatedDt
      FROM grac_practice.asset_form_template t
      JOIN grac_practice.entity_status_master s ON s.entity_status_id = t.current_status_id
      JOIN grac_practice.dependency_asset_type_master at ON at.asset_type_id = t.asset_type_id
      JOIN grac_practice.dependency_asset_subcategory_master sc ON sc.subcategory_id = at.subcategory_id
      JOIN grac_practice.dependency_asset_category_master ac ON ac.asset_category_id = sc.asset_category_id
      LEFT JOIN grac_practice.organization_employee o ON o.employee_id = t.template_owner_employee_id
      LEFT JOIN grac_practice.asset_form_template src ON src.template_id = t.source_template_id
     WHERE t.template_id = @template_id AND t.organization_id = @organization_id;

    -- 2. Sections.
    SELECT x.section_id AS SectionId, x.section_key AS SectionKey, x.section_label AS SectionLabel,
           x.tab_label AS TabLabel, x.layout_columns AS LayoutColumns, x.display_order AS DisplayOrder,
           x.is_system AS IsSystem, x.is_active AS IsActive,
           (SELECT COUNT(*) FROM grac_practice.asset_form_template_field f WHERE f.section_id = x.section_id) AS FieldCount
      FROM grac_practice.asset_form_template_section x
      JOIN grac_practice.asset_form_template t ON t.template_id = x.template_id
     WHERE x.template_id = @template_id AND t.organization_id = @organization_id
     ORDER BY x.display_order, x.section_label;

    -- 3. Fields, with their dictionary definition.
    SELECT f.template_field_id AS TemplateFieldId, f.field_definition_id AS FieldDefinitionId,
           d.field_key AS FieldKey, d.display_label AS DisplayLabel, g.group_code AS GroupCode, g.group_name AS GroupName,
           d.data_type_code AS DataTypeCode, d.lookup_source AS LookupSource, d.storage_kind AS StorageKind,
           d.is_system_mandatory AS IsSystemMandatory, d.sensitivity_code AS BaselineSensitivity,
           d.status_code AS DefinitionStatus,
           f.section_id AS SectionId, f.display_order AS DisplayOrder,
           f.is_visible AS IsVisible, f.is_mandatory AS IsMandatory, f.is_read_only AS IsReadOnly,
           f.default_value AS DefaultValue, f.help_text AS HelpText, f.placeholder_text AS PlaceholderText,
           f.hidden_value_behavior AS HiddenValueBehavior, f.sensitivity_override AS SensitivityOverride,
           f.include_in_import_export AS IncludeInImportExport, f.is_searchable AS IsSearchable,
           f.evidence_required AS EvidenceRequired
      FROM grac_practice.asset_form_template_field f
      JOIN grac_practice.asset_form_template t ON t.template_id = f.template_id
      JOIN grac_practice.asset_field_definition d ON d.field_definition_id = f.field_definition_id
      JOIN grac_practice.asset_field_group_master g ON g.field_group_id = d.field_group_id
      JOIN grac_practice.asset_form_template_section x ON x.section_id = f.section_id
     WHERE f.template_id = @template_id AND t.organization_id = @organization_id
     ORDER BY x.display_order, f.display_order, d.display_label;

    -- 4. Status history (immutable framework log).
    SELECT l.transition_log_id AS TransitionLogId, fs.status_name AS FromStatus, ts.status_name AS ToStatus,
           l.actor_employee_id AS ActorEmployeeId, e.employee_name AS ActorName,
           l.reason_code AS ReasonCode, l.reason_text AS ReasonText, l.transitioned_at AS TransitionedAt
      FROM grac_practice.entity_state_transition_log l
      JOIN grac_practice.asset_form_template t ON t.template_id = l.entity_id
      LEFT JOIN grac_practice.entity_status_master fs ON fs.entity_status_id = l.from_status_id
      JOIN grac_practice.entity_status_master ts ON ts.entity_status_id = l.to_status_id
      LEFT JOIN grac_practice.organization_employee e ON e.employee_id = l.actor_employee_id
     WHERE l.entity_type = N'AssetFormTemplate' AND l.entity_id = @template_id
       AND t.organization_id = @organization_id
     ORDER BY l.transitioned_at DESC, l.transition_log_id DESC;

    -- 5. Conditional rules (421).
    SELECT r.rule_id AS RuleId, r.rule_name AS RuleName, r.target_field_definition_id AS TargetFieldDefinitionId,
           d.field_key AS TargetFieldKey, d.display_label AS TargetLabel, r.action_code AS ActionCode,
           r.display_order AS DisplayOrder, r.is_active AS IsActive
      FROM grac_practice.asset_form_template_rule r
      JOIN grac_practice.asset_form_template t ON t.template_id = r.template_id
      JOIN grac_practice.asset_field_definition d ON d.field_definition_id = r.target_field_definition_id
     WHERE r.template_id = @template_id AND t.organization_id = @organization_id
     ORDER BY r.display_order, r.rule_id;

    -- 6. Rule conditions (421).
    SELECT c.condition_id AS ConditionId, c.rule_id AS RuleId, c.group_no AS GroupNo,
           c.source_field_definition_id AS SourceFieldDefinitionId, d.field_key AS SourceFieldKey,
           d.display_label AS SourceLabel, c.operator_code AS OperatorCode, c.compare_value AS CompareValue
      FROM grac_practice.asset_form_template_rule_condition c
      JOIN grac_practice.asset_form_template_rule r ON r.rule_id = c.rule_id
      JOIN grac_practice.asset_form_template t ON t.template_id = r.template_id
      JOIN grac_practice.asset_field_definition d ON d.field_definition_id = c.source_field_definition_id
     WHERE r.template_id = @template_id AND t.organization_id = @organization_id
     ORDER BY c.rule_id, c.group_no, c.display_order;

    -- 7. Option values for the template's OPTION: fields (421).
    SELECT d.field_definition_id AS FieldDefinitionId, o.option_value AS OptionValue, o.option_label AS OptionLabel,
           o.display_order AS DisplayOrder
      FROM grac_practice.asset_form_template_field f
      JOIN grac_practice.asset_form_template t ON t.template_id = f.template_id
      JOIN grac_practice.asset_field_definition d ON d.field_definition_id = f.field_definition_id
      JOIN grac_practice.reference_option o
           ON d.lookup_source LIKE N'OPTION:%'
          AND o.option_group = N'asset_field.' + SUBSTRING(d.lookup_source, 8, 100)
          AND o.status = N'Active'
     WHERE f.template_id = @template_id AND t.organization_id = @organization_id

    UNION ALL

    -- 422: CIA rating fields (CONFIG:CIA_SCALE) list the levels of the
    -- organization's Active valuation configuration for their dimension.
    SELECT d.field_definition_id, CAST(l.score AS NVARCHAR(160)), CONCAT(l.score, N' - ', l.level_label), l.display_order
      FROM grac_practice.asset_form_template_field f
      JOIN grac_practice.asset_form_template t ON t.template_id = f.template_id
      JOIN grac_practice.asset_field_definition d ON d.field_definition_id = f.field_definition_id
      JOIN grac_practice.asset_valuation_config c ON c.organization_id = t.organization_id AND c.is_active_version = 1
      JOIN grac_practice.asset_cia_scale_level l
           ON l.config_id = c.config_id
          AND l.dimension_code = CASE d.field_key WHEN N'confidentiality_rating' THEN N'C'
                                                  WHEN N'integrity_rating' THEN N'I'
                                                  WHEN N'availability_rating' THEN N'A' END
     WHERE f.template_id = @template_id AND t.organization_id = @organization_id
       AND d.lookup_source = N'CONFIG:CIA_SCALE'
     ORDER BY 1, 4, 3;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_asset_form_template_readiness
    @organization_id   BIGINT,
    @template_id       BIGINT,
    @suppress_result   BIT = 0,
    @out_error_count   INT = NULL OUTPUT,
    @out_warning_count INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @issues TABLE (
        check_code NVARCHAR(60)  NOT NULL,
        severity   NVARCHAR(10)  NOT NULL,
        message    NVARCHAR(400) NOT NULL,
        field_key  NVARCHAR(100) NULL);

    IF NOT EXISTS (SELECT 1 FROM grac_practice.asset_form_template
                    WHERE template_id = @template_id AND organization_id = @organization_id)
        THROW 54202, 'Asset form template not found for this organization.', 1;

    -- Baseline: every active system-mandatory field present, visible, mandatory.
    INSERT @issues (check_code, severity, message, field_key)
    SELECT N'BASELINE_MISSING', N'ERROR',
           CONCAT(N'System-mandatory field "', d.display_label, N'" is not on the form.'), d.field_key
      FROM grac_practice.asset_field_definition d
     WHERE d.is_system_mandatory = 1 AND d.status_code = N'ACTIVE' AND d.is_system_field = 0
       AND NOT EXISTS (SELECT 1 FROM grac_practice.asset_form_template_field f
                        WHERE f.template_id = @template_id AND f.field_definition_id = d.field_definition_id);

    INSERT @issues (check_code, severity, message, field_key)
    SELECT N'BASELINE_WEAKENED', N'ERROR',
           CONCAT(N'System-mandatory field "', d.display_label, N'" must stay visible and mandatory.'), d.field_key
      FROM grac_practice.asset_form_template_field f
      JOIN grac_practice.asset_field_definition d ON d.field_definition_id = f.field_definition_id
     WHERE f.template_id = @template_id AND d.is_system_mandatory = 1
       AND (f.is_visible = 0 OR f.is_mandatory = 0);

    INSERT @issues (check_code, severity, message, field_key)
    SELECT N'RETIRED_DEFINITION', N'ERROR',
           CONCAT(N'Field "', d.display_label, N'" is retired in the dictionary; remove it.'), d.field_key
      FROM grac_practice.asset_form_template_field f
      JOIN grac_practice.asset_field_definition d ON d.field_definition_id = f.field_definition_id
     WHERE f.template_id = @template_id AND d.status_code <> N'ACTIVE';

    INSERT @issues (check_code, severity, message, field_key)
    SELECT N'INACTIVE_SECTION', N'ERROR',
           CONCAT(N'Field "', d.display_label, N'" is placed in an inactive section.'), d.field_key
      FROM grac_practice.asset_form_template_field f
      JOIN grac_practice.asset_field_definition d ON d.field_definition_id = f.field_definition_id
      JOIN grac_practice.asset_form_template_section x ON x.section_id = f.section_id
     WHERE f.template_id = @template_id AND x.is_active = 0;

    INSERT @issues (check_code, severity, message, field_key)
    SELECT N'HIDDEN_MANDATORY', CASE WHEN f.default_value IS NULL THEN N'ERROR' ELSE N'WARNING' END,
           CONCAT(N'Field "', d.display_label, N'" is mandatory but hidden',
                  CASE WHEN f.default_value IS NULL THEN N' and has no default value.' ELSE N'; its default value will be used.' END),
           d.field_key
      FROM grac_practice.asset_form_template_field f
      JOIN grac_practice.asset_field_definition d ON d.field_definition_id = f.field_definition_id
     WHERE f.template_id = @template_id AND f.is_mandatory = 1 AND f.is_visible = 0
       AND d.is_system_mandatory = 0;

    INSERT @issues (check_code, severity, message, field_key)
    SELECT N'READONLY_MANDATORY', N'WARNING',
           CONCAT(N'Field "', d.display_label, N'" is mandatory and read-only with no default; users cannot fill it.'), d.field_key
      FROM grac_practice.asset_form_template_field f
      JOIN grac_practice.asset_field_definition d ON d.field_definition_id = f.field_definition_id
      JOIN grac_practice.asset_field_data_type_master dt ON dt.data_type_code = d.data_type_code
     WHERE f.template_id = @template_id AND f.is_mandatory = 1 AND f.is_read_only = 1
       AND f.default_value IS NULL AND dt.is_user_entered = 1;

    -- 421: an OPTION: list counts as configured once it has an Active
    -- value; CONFIG: sources are served by configuration screens that
    -- arrive with the CIA / criticality increment.
    INSERT @issues (check_code, severity, message, field_key)
    SELECT N'OPTIONS_PENDING', N'WARNING',
           CONCAT(N'Field "', d.display_label, N'" has no option values configured yet.'), d.field_key
      FROM grac_practice.asset_form_template_field f
      JOIN grac_practice.asset_field_definition d ON d.field_definition_id = f.field_definition_id
     WHERE f.template_id = @template_id AND d.lookup_source LIKE N'OPTION:%'
       AND NOT EXISTS (SELECT 1 FROM grac_practice.reference_option o
                        WHERE o.option_group = N'asset_field.' + SUBSTRING(d.lookup_source, 8, 100) AND o.status = N'Active');

    INSERT @issues (check_code, severity, message, field_key)
    SELECT N'CONFIG_PENDING', N'WARNING',
           CONCAT(N'Field "', d.display_label, N'" takes its values from configuration (', d.lookup_source,
                  CASE WHEN d.lookup_source = N'CONFIG:CIA_SCALE'
                       THEN N') -- activate an Asset Valuation configuration for this organization.'
                       ELSE N') that is delivered in a later increment.' END), d.field_key
      FROM grac_practice.asset_form_template_field f
      JOIN grac_practice.asset_field_definition d ON d.field_definition_id = f.field_definition_id
     WHERE f.template_id = @template_id AND d.lookup_source LIKE N'CONFIG:%'
       -- 422: CIA_SCALE is delivered once the organization has an Active
       -- valuation configuration.
       AND NOT (d.lookup_source = N'CONFIG:CIA_SCALE'
                AND EXISTS (SELECT 1 FROM grac_practice.asset_form_template t
                              JOIN grac_practice.asset_valuation_config c
                                ON c.organization_id = t.organization_id AND c.is_active_version = 1
                             WHERE t.template_id = @template_id));

    -- 421: conditional rules.
    INSERT @issues (check_code, severity, message, field_key)
    SELECT N'RULE_TARGET_MISSING', N'ERROR', CONCAT(N'Rule "', r.rule_name, N'" targets a field that is not on the form.'), d.field_key
      FROM grac_practice.asset_form_template_rule r
      JOIN grac_practice.asset_field_definition d ON d.field_definition_id = r.target_field_definition_id
     WHERE r.template_id = @template_id AND r.is_active = 1
       AND NOT EXISTS (SELECT 1 FROM grac_practice.asset_form_template_field f
                        WHERE f.template_id = @template_id AND f.field_definition_id = r.target_field_definition_id);

    INSERT @issues (check_code, severity, message, field_key)
    SELECT N'RULE_SOURCE_MISSING', N'ERROR', CONCAT(N'Rule "', r.rule_name, N'" tests "', d.display_label, N'", which is not on the form.'), d.field_key
      FROM grac_practice.asset_form_template_rule r
      JOIN grac_practice.asset_form_template_rule_condition c ON c.rule_id = r.rule_id
      JOIN grac_practice.asset_field_definition d ON d.field_definition_id = c.source_field_definition_id
     WHERE r.template_id = @template_id AND r.is_active = 1
       AND NOT EXISTS (SELECT 1 FROM grac_practice.asset_form_template_field f
                        WHERE f.template_id = @template_id AND f.field_definition_id = c.source_field_definition_id);

    INSERT @issues (check_code, severity, message, field_key)
    SELECT N'RULE_NO_CONDITION', N'ERROR', CONCAT(N'Rule "', r.rule_name, N'" has no conditions.'), NULL
      FROM grac_practice.asset_form_template_rule r
     WHERE r.template_id = @template_id AND r.is_active = 1
       AND NOT EXISTS (SELECT 1 FROM grac_practice.asset_form_template_rule_condition c WHERE c.rule_id = r.rule_id);

    INSERT @issues (check_code, severity, message, field_key)
    SELECT N'RULE_ON_BASELINE', N'ERROR', CONCAT(N'Rule "', r.rule_name, N'" targets a system-mandatory field.'), d.field_key
      FROM grac_practice.asset_form_template_rule r
      JOIN grac_practice.asset_field_definition d ON d.field_definition_id = r.target_field_definition_id
     WHERE r.template_id = @template_id AND r.is_active = 1 AND d.is_system_mandatory = 1;

    INSERT @issues (check_code, severity, message, field_key)
    SELECT DISTINCT N'RULE_SOURCE_HIDDEN', N'WARNING',
           CONCAT(N'"', d.display_label, N'" drives a rule but is hidden on the form; users cannot set it.'), d.field_key
      FROM grac_practice.asset_form_template_rule r
      JOIN grac_practice.asset_form_template_rule_condition c ON c.rule_id = r.rule_id
      JOIN grac_practice.asset_form_template_field f ON f.template_id = r.template_id AND f.field_definition_id = c.source_field_definition_id
      JOIN grac_practice.asset_field_definition d ON d.field_definition_id = c.source_field_definition_id
     WHERE r.template_id = @template_id AND r.is_active = 1 AND f.is_visible = 0
       AND NOT EXISTS (SELECT 1 FROM grac_practice.asset_form_template_rule r2
                        WHERE r2.template_id = r.template_id AND r2.is_active = 1
                          AND r2.target_field_definition_id = c.source_field_definition_id
                          AND r2.action_code IN (N'SHOW', N'SHOW_AND_REQUIRE'));

    -- Loop check over the whole rule graph (rule saves already refuse
    -- loops; this catches data written any other way).
    DECLARE @edges TABLE (source_id INT NOT NULL, target_id INT NOT NULL);
    INSERT @edges (source_id, target_id)
    SELECT DISTINCT c.source_field_definition_id, r.target_field_definition_id
      FROM grac_practice.asset_form_template_rule r
      JOIN grac_practice.asset_form_template_rule_condition c ON c.rule_id = r.rule_id
     WHERE r.template_id = @template_id AND r.is_active = 1;
    DECLARE @walk TABLE (start_id INT NOT NULL, field_id INT NOT NULL, PRIMARY KEY (start_id, field_id));
    INSERT @walk (start_id, field_id) SELECT DISTINCT target_id, target_id FROM @edges;
    DECLARE @added INT = 1, @guard INT = 0;
    WHILE @added > 0 AND @guard < 500
    BEGIN
        INSERT @walk (start_id, field_id)
        SELECT DISTINCT w.start_id, e.target_id
          FROM @walk w JOIN @edges e ON e.source_id = w.field_id
         WHERE NOT EXISTS (SELECT 1 FROM @walk x WHERE x.start_id = w.start_id AND x.field_id = e.target_id);
        SET @added = @@ROWCOUNT;
        SET @guard = @guard + 1;
    END
    INSERT @issues (check_code, severity, message, field_key)
    SELECT N'RULE_CIRCULAR', N'ERROR', CONCAT(N'"', d.display_label, N'" depends on itself through its rules.'), d.field_key
      FROM grac_practice.asset_field_definition d
     WHERE EXISTS (SELECT 1 FROM @edges e JOIN @walk w ON w.field_id = e.source_id AND w.start_id = e.target_id
                    WHERE e.target_id = d.field_definition_id);

    INSERT @issues (check_code, severity, message, field_key)
    SELECT N'EMPTY_SECTION', N'WARNING', CONCAT(N'Section "', x.section_label, N'" has no fields and will be hidden.'), NULL
      FROM grac_practice.asset_form_template_section x
     WHERE x.template_id = @template_id AND x.is_active = 1 AND x.is_system = 0
       AND NOT EXISTS (SELECT 1 FROM grac_practice.asset_form_template_field f WHERE f.section_id = x.section_id);

    INSERT @issues (check_code, severity, message, field_key)
    SELECT N'OWNER_MISSING', N'ERROR', N'Template owner is required.', NULL
      FROM grac_practice.asset_form_template t
     WHERE t.template_id = @template_id AND t.template_owner_employee_id IS NULL;

    INSERT @issues (check_code, severity, message, field_key)
    SELECT N'REASON_MISSING', N'ERROR', N'Change reason is required for a new version.', NULL
      FROM grac_practice.asset_form_template t
     WHERE t.template_id = @template_id AND t.version_no > 1
       AND NULLIF(LTRIM(RTRIM(t.change_reason)), N'') IS NULL;

    INSERT @issues (check_code, severity, message, field_key)
    SELECT N'ASSET_TYPE_INACTIVE', N'ERROR', N'The asset type is no longer active.', NULL
      FROM grac_practice.asset_form_template t
      JOIN grac_practice.dependency_asset_type_master at ON at.asset_type_id = t.asset_type_id
     WHERE t.template_id = @template_id AND at.is_active = 0;

    SELECT @out_error_count   = COUNT(CASE WHEN severity = N'ERROR' THEN 1 END),
           @out_warning_count = COUNT(CASE WHEN severity = N'WARNING' THEN 1 END)
      FROM @issues;

    IF ISNULL(@suppress_result, 0) = 1 RETURN;

    SELECT check_code AS CheckCode, severity AS Severity, message AS Message, field_key AS FieldKey
      FROM @issues
     ORDER BY CASE severity WHEN N'ERROR' THEN 0 ELSE 1 END, check_code, field_key;
END
GO
PRINT '422: procedures created / re-issued.';
GO

-- =====================================================================
-- 8. Menu: Asset & Contract -> Asset Valuation (also carried in 274)
-- =====================================================================
MERGE grac_practice.menu_master AS t
USING (VALUES
    (N'asset-valuation-config', N'Asset Valuation', N'Practice/Index/asset-valuation-config', 353, N'scale-balanced', N'Asset & Contract')
) AS s(menu_key, menu_name, menu_url, display_order, icon_class, module_type)
ON t.menu_key = s.menu_key
WHEN MATCHED AND (ISNULL(t.menu_name, N'') <> s.menu_name OR ISNULL(t.menu_url, N'') <> s.menu_url
               OR t.display_order <> s.display_order OR ISNULL(t.icon_class, N'') <> s.icon_class
               OR ISNULL(t.module_type, N'') <> s.module_type OR t.status <> N'Active') THEN UPDATE SET
    menu_name = s.menu_name, menu_url = s.menu_url, display_order = s.display_order, icon_class = s.icon_class,
    module_type = s.module_type, status = N'Active', updated_by = N'seed-422', updated_dt = SYSUTCDATETIME()
WHEN NOT MATCHED BY TARGET THEN
    INSERT (menu_key, menu_name, menu_url, display_order, icon_class, module_type, status, entered_by)
    VALUES (s.menu_key, s.menu_name, s.menu_url, s.display_order, s.icon_class, s.module_type, N'Active', N'seed-422');
PRINT CONCAT('422: menu row upserted: ', @@ROWCOUNT);
GO

UPDATE c
   SET parent_menu_id = p.menu_id, updated_by = N'seed-422', updated_dt = SYSUTCDATETIME()
  FROM grac_practice.menu_master c
  JOIN grac_practice.menu_master p ON p.menu_key = N'nav-asset-contract'
 WHERE c.menu_key = N'asset-valuation-config' AND ISNULL(c.parent_menu_id, -1) <> p.menu_id;
GO

DECLARE @active_rs INT = (
    SELECT TOP 1 record_status_id FROM grac_practice.record_status_master
     WHERE status_code = N'Active' OR status_name = N'Active' ORDER BY record_status_id);
IF @active_rs IS NULL SET @active_rs = 1;
INSERT grac_practice.organization_role_menu_permission
    (role_id, menu_id, can_view, can_add, can_edit, can_delete, can_approve, status, record_status_id, entered_by, entered_dt)
SELECT r.role_id, m.menu_id, 1, 1, 1, 0, 1, N'Active', @active_rs, N'seed-422', SYSUTCDATETIME()
  FROM grac_practice.organization_role r
  JOIN grac_practice.menu_master m ON m.menu_key = N'asset-valuation-config'
 WHERE r.role_name = N'Admin' AND r.status = N'Active'
   AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_role_menu_permission e
                    WHERE e.role_id = r.role_id AND e.menu_id = m.menu_id);
PRINT CONCAT('422: Admin grants inserted: ', @@ROWCOUNT);
GO

-- =====================================================================
-- Verification
-- =====================================================================
SELECT '422-a valuation tables present' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.asset_valuation_config','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.asset_cia_scale_level','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.asset_value_band','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.asset_criticality_level','U') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '422-b AssetValuationConfig: 5 statuses, 8 transitions',
       CASE WHEN (SELECT COUNT(*) FROM grac_practice.entity_status_master WHERE entity_type = N'AssetValuationConfig') = 5
             AND (SELECT COUNT(*) FROM grac_practice.entity_state_transition_rule WHERE entity_type = N'AssetValuationConfig' AND is_active = 1) = 8
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '422-c procedures + calculation function present',
       CASE WHEN (SELECT COUNT(*) FROM sys.procedures WHERE SCHEMA_NAME(schema_id) = 'grac_practice'
                   AND name IN ('sp_asset_valuation_config_list', 'sp_asset_valuation_config_get', 'sp_asset_valuation_config_readiness',
                                'sp_asset_valuation_config_assert_editable', 'sp_asset_valuation_config_create',
                                'sp_asset_valuation_config_header_save', 'sp_asset_valuation_config_item_save',
                                'sp_asset_valuation_config_transition', 'sp_asset_valuation_calculate')) = 9
             AND OBJECT_ID('grac_practice.fn_asset_value_calc') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '422-d template get lists the CIA scale (re-issued)',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_asset_form_template_get')) LIKE '%asset_cia_scale_level%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '422-e menu row Active under Asset & Contract',
       CASE WHEN EXISTS (SELECT 1 FROM grac_practice.menu_master c
                           JOIN grac_practice.menu_master p ON p.menu_id = c.parent_menu_id AND p.menu_key = N'nav-asset-contract'
                          WHERE c.menu_key = N'asset-valuation-config' AND c.status = N'Active') THEN 'PASS' ELSE 'FAIL' END;
GO

-- =====================================================================
-- UAT (after deploying the API + Web build; re-login for the menu grant)
--   1. Asset & Contract -> Asset Valuation -> New Configuration: Draft v1
--      with the 1-5 Negligible..Critical scale for C, I and A, Maximum
--      method, and the current Criticality values. Readiness: BANDS_EMPTY.
--   2. Add bands 1-2 Low, 3 Medium, 4 High, 5 Critical; add 2-3 ->
--      refused (54262, overlap). Readiness clean.
--   3. Switch to Weighted Average with 40/40/10 -> Submit refused (54263,
--      WEIGHTS_TOTAL); 40/40/20 -> bands now need 2-decimal coverage
--      (1.00-5.00); fix and Submit.
--   4. Approve as the submitter -> refused (54264); approve as another
--      user -> Approved; Activate -> Active. Edit -> refused (54252).
--   5. Calculator: C=5, I=2, A=1 on Maximum -> 5.00 Critical.
--   6. Asset Form Templates: the Confidentiality / Integrity /
--      Availability rating fields now offer the 1-5 levels; readiness no
--      longer shows CONFIG_PENDING for them.
--   7. New Version (reason required) copies scale, bands and criticality;
--      activating it retires v1 with effective-to set.
-- =====================================================================
SET NOEXEC OFF;
GO
