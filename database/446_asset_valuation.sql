-- =====================================================================
-- 446  Asset Value per asset -- automatic CIA valuation, validation
--      status, history, asset-level method override, controlled
--      recalculation with impact analysis
--      (Asset & Contract Management, Phase 8 increment 1)
--
-- REQUEST
-- -------
--   BRD v1.7 5.1.18 (Asset Value and CIA Valuation Framework),
--   5.1.18.3 (risk integration -- the stored value is what the risk
--   module reads), 5.1.18.4 (acceptance), 5.1.18.5.3 (method override),
--   5.1.18.5.6 (asset-type defaults), 5.1.18.5.7 (automatic calculation
--   and recalculation), 5.1.18.5.8 (version used, audit, impact
--   analysis, historical calculations unchanged), 5.1.18.5.9 ("CIA
--   changes automatically recalculate"; "existing assets are not
--   silently changed"). Plan: docs/asset-contract-management.md
--   (Phase 8.1, D132-D141).
--
-- WHAT THIS DOES
-- --------------
--   1. asset_valuation_result: the current Asset Value of each asset --
--      the CIA ratings and method used, score, category, band, the
--      valuation configuration (and so the CIA scale, method, band and
--      criticality version) used, a validation status (NOT_RATED,
--      INCOMPLETE, INVALID, VALID) and message, source and actor.
--      asset_valuation_history: every calculation, previous and new
--      values, source, reason, run, actor, time (append-only).
--      asset_valuation_recalc_run: controlled recalculation runs.
--   2. fn_asset_value_calc_method: the 422 calculation with an explicit
--      method (asset-level override); fn_asset_value_calc (422) now calls
--      it, so there is one formula.
--   3. fn_asset_valuation_eval: the Asset Value of each asset under the
--      Active configuration now; fn_asset_valuation_state: that compared
--      with the stored result -- current, values changed (CIA / method
--      changed by the form, a merge, a split, discovery), configuration
--      changed (a new version was activated), or never calculated.
--   4. sp_asset_valuation_apply: stores a calculation. AUTO mode (asset
--      form save, scheduler) applies only when the ratings or method
--      changed or nothing was stored; CONTROLLED mode (single-asset
--      recalculation, recalculation run) applies any difference.
--   5. sp_asset_register_save (435) re-issued: recalculates after a save,
--      warns when the result is incomplete / invalid / waiting for a
--      recalculation run, refuses a changed Asset Valuation Method that
--      differs from the configured method (overrides go through
--      sp_asset_valuation_method_set: enabled in the configuration, an
--      approver, a reason), and no longer takes a template default for the
--      method (the configuration supplies it).
--   6. sp_asset_scheduler_run (438) re-issued: per organization,
--      sp_asset_valuation_sync applies AUTO recalculations for ratings
--      changed outside the form.
--   7. fn_asset_stored_values (439) re-issued: Asset Value Score and
--      Asset Value Category show the stored VALID result (read-only).
--   8. Readers: sp_asset_valuation_get (one asset: current, state,
--      history), sp_asset_valuation_recalc_preview (impact analysis:
--      affected assets, category moves, linked risks, runs);
--      writers: sp_asset_valuation_recalculate (one asset),
--      sp_asset_valuation_recalc_run (all affected assets, reason,
--      expected count from the preview).
--
-- NOT DONE HERE: CIA / criticality consistency rules and the risk-score
--   refresh (8.2); defaults inherited from category / subcategory
--   (templates already carry per-asset-type defaults); per-scope
--   configurations (one per organization, as 422).
--
-- ERROR NUMBERS: 53000-53009
--   53000 asset not found                53001 no Active configuration
--   53002 invalid valuation method       53003 method override not enabled
--   53004 reason required                53005 affected assets changed
--                                              since the preview
--   53006 another recalculation running  53007 organization not found
--
-- ALSO EDITED: API (AssetConfig service / controller / models), Web
--   proxy, asset-register.cshtml / .js (Valuation section),
--   asset-valuation-config.cshtml / .js (Recalculation tab), docs.
-- DEPENDS ON: 422, 428, 435, 438, 439 (and 265 for the risk links).
-- Rollback: 446_asset_valuation_rollback.sql (restores the 422, 435,
--   438 and 439 bodies, drops the 446 objects).
-- Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.asset_valuation_config','U') IS NULL
   OR OBJECT_ID('grac_practice.asset_cia_scale_level','U') IS NULL
   OR OBJECT_ID('grac_practice.asset_value_band','U') IS NULL
   OR OBJECT_ID('grac_practice.asset_field_value','U') IS NULL
   OR OBJECT_ID('grac_practice.fn_asset_value_calc') IS NULL
   OR OBJECT_ID('grac_practice.fn_asset_coverage_summary') IS NULL
   OR OBJECT_ID('grac_practice.fn_asset_coverage_gaps') IS NULL
   OR OBJECT_ID('grac_practice.sp_asset_assignment_snapshot','P') IS NULL
   OR OBJECT_ID('grac_practice.sp_asset_tech_install_apply','P') IS NULL
   OR OBJECT_ID('grac_practice.asset_activity_schedule','U') IS NULL
   OR OBJECT_ID('grac_practice.sp_asset_activity_run','P') IS NULL
   OR OBJECT_ID('grac_practice.sp_asset_notification_sweep','P') IS NULL
   OR OBJECT_ID('grac_practice.sp_asset_contract_renewal_start','P') IS NULL
   OR OBJECT_ID('grac_practice.asset_scheduler_run','U') IS NULL
   OR COL_LENGTH('grac_practice.asset_scheduler_run','tasks_created') IS NULL
   OR COL_LENGTH('grac_practice.organization_dependency_asset','template_id') IS NULL
   OR COL_LENGTH('grac_practice.organization_dependency_asset','merged_into_asset_id') IS NULL
   OR OBJECT_ID('grac_practice.risk_dependency_map','U') IS NULL
   OR COL_LENGTH('grac_practice.dependency_type_master','dependency_type_code') IS NULL
   OR NOT EXISTS (SELECT 1 FROM grac_practice.asset_field_definition WHERE field_key = N'asset_value_score')
BEGIN
    RAISERROR('ABORT (446): run 265, 422, 428, 435, 438, 439 and 444 first.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. Tables
-- =====================================================================
IF OBJECT_ID('grac_practice.asset_valuation_recalc_run','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_valuation_recalc_run (
        run_id            BIGINT         IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_asset_val_run PRIMARY KEY,
        organization_id   BIGINT         NOT NULL
            CONSTRAINT fk_pm_asset_val_run_org REFERENCES grac_practice.organization(organization_id),
        config_id         BIGINT         NULL
            CONSTRAINT fk_pm_asset_val_run_cfg REFERENCES grac_practice.asset_valuation_config(config_id),
        reason_text       NVARCHAR(1000) NOT NULL,
        status            NVARCHAR(30)   NOT NULL CONSTRAINT df_pm_asset_val_run_status DEFAULT N'RUNNING'
            CONSTRAINT ck_pm_asset_val_run_status CHECK (status IN (N'RUNNING', N'COMPLETED', N'COMPLETED_WITH_ERRORS', N'FAILED')),
        affected_count    INT            NOT NULL CONSTRAINT df_pm_asset_val_run_aff DEFAULT 0,
        updated_count     INT            NOT NULL CONSTRAINT df_pm_asset_val_run_upd DEFAULT 0,
        error_count       INT            NOT NULL CONSTRAINT df_pm_asset_val_run_err DEFAULT 0,
        error_text        NVARCHAR(4000) NULL,
        actor_employee_id BIGINT         NULL,
        started_dt        DATETIME2      NOT NULL CONSTRAINT df_pm_asset_val_run_sdt DEFAULT SYSUTCDATETIME(),
        finished_dt       DATETIME2      NULL,
        entered_by        NVARCHAR(100)  NOT NULL
    );
    CREATE INDEX ix_pm_asset_val_run_org ON grac_practice.asset_valuation_recalc_run(organization_id, run_id DESC);
    PRINT '446: asset_valuation_recalc_run created.';
END
GO

IF OBJECT_ID('grac_practice.asset_valuation_history','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_valuation_history (
        history_id          BIGINT         IDENTITY(1,1) NOT NULL CONSTRAINT pk_pm_asset_val_hist PRIMARY KEY,
        organization_id     BIGINT         NOT NULL,
        asset_id            BIGINT         NOT NULL
            CONSTRAINT fk_pm_asset_val_hist_asset REFERENCES grac_practice.organization_dependency_asset(asset_id),
        source              NVARCHAR(30)   NOT NULL
            CONSTRAINT ck_pm_asset_val_hist_source CHECK (source IN (N'FORM', N'SCHEDULER', N'MANUAL', N'RECALC_RUN', N'METHOD_OVERRIDE')),
        run_id              BIGINT         NULL
            CONSTRAINT fk_pm_asset_val_hist_run REFERENCES grac_practice.asset_valuation_recalc_run(run_id),
        reason_text         NVARCHAR(1000) NULL,
        prev_config_id      BIGINT         NULL,
        prev_config_version INT            NULL,
        prev_confidentiality NVARCHAR(40)  NULL,
        prev_integrity      NVARCHAR(40)   NULL,
        prev_availability   NVARCHAR(40)   NULL,
        prev_method_used    NVARCHAR(30)   NULL,
        prev_score          DECIMAL(18, 4) NULL,
        prev_category       NVARCHAR(100)  NULL,
        prev_status         NVARCHAR(20)   NULL,
        new_config_id       BIGINT         NULL,
        new_config_version  INT            NULL,
        confidentiality     NVARCHAR(40)   NULL,
        integrity           NVARCHAR(40)   NULL,
        availability        NVARCHAR(40)   NULL,
        method_override     NVARCHAR(30)   NULL,
        method_used         NVARCHAR(30)   NULL,
        method_source       NVARCHAR(10)   NULL,
        raw_score           DECIMAL(18, 6) NULL,
        new_score           DECIMAL(18, 4) NULL,
        new_category        NVARCHAR(100)  NULL,
        new_band_id         BIGINT         NULL,
        new_status          NVARCHAR(20)   NOT NULL,
        message             NVARCHAR(500)  NULL,
        actor_employee_id   BIGINT         NULL,
        entered_by          NVARCHAR(100)  NOT NULL,
        entered_dt          DATETIME2      NOT NULL CONSTRAINT df_pm_asset_val_hist_edt DEFAULT SYSUTCDATETIME()
    );
    CREATE INDEX ix_pm_asset_val_hist_asset ON grac_practice.asset_valuation_history(asset_id, history_id DESC);
    CREATE INDEX ix_pm_asset_val_hist_run ON grac_practice.asset_valuation_history(run_id) WHERE run_id IS NOT NULL;
    PRINT '446: asset_valuation_history created.';
END
GO

IF OBJECT_ID('grac_practice.asset_valuation_result','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.asset_valuation_result (
        asset_id           BIGINT         NOT NULL CONSTRAINT pk_pm_asset_val_result PRIMARY KEY
            CONSTRAINT fk_pm_asset_val_result_asset REFERENCES grac_practice.organization_dependency_asset(asset_id),
        organization_id    BIGINT         NOT NULL,
        config_id          BIGINT         NULL
            CONSTRAINT fk_pm_asset_val_result_cfg REFERENCES grac_practice.asset_valuation_config(config_id),
        config_version_no  INT            NULL,
        confidentiality    NVARCHAR(40)   NULL,
        integrity          NVARCHAR(40)   NULL,
        availability       NVARCHAR(40)   NULL,
        method_override    NVARCHAR(30)   NULL,
        method_used        NVARCHAR(30)   NULL,
        method_source      NVARCHAR(10)   NULL
            CONSTRAINT ck_pm_asset_val_result_msrc CHECK (method_source IS NULL OR method_source IN (N'CONFIG', N'OVERRIDE')),
        raw_score          DECIMAL(18, 6) NULL,
        asset_value_score  DECIMAL(18, 4) NULL,
        asset_value_category NVARCHAR(100) NULL,
        band_id            BIGINT         NULL,
        validation_status  NVARCHAR(20)   NOT NULL
            CONSTRAINT ck_pm_asset_val_result_status CHECK (validation_status IN (N'NOT_RATED', N'INCOMPLETE', N'INVALID', N'VALID')),
        validation_message NVARCHAR(500)  NULL,
        source             NVARCHAR(30)   NOT NULL,
        run_id             BIGINT         NULL,
        last_history_id    BIGINT         NULL,
        calculated_by      NVARCHAR(100)  NOT NULL,
        calculated_dt      DATETIME2      NOT NULL CONSTRAINT df_pm_asset_val_result_cdt DEFAULT SYSUTCDATETIME(),
        record_version     ROWVERSION     NOT NULL
    );
    CREATE INDEX ix_pm_asset_val_result_org ON grac_practice.asset_valuation_result(organization_id, validation_status, asset_value_category);
    PRINT '446: asset_valuation_result created.';
END
GO

-- =====================================================================
-- 2. Calculation with an explicit method (D133). fn_asset_value_calc
--    (422) is re-issued to call it with the configured method, so the
--    Calculator tab, the register and the risk module share one formula.
-- =====================================================================
CREATE OR ALTER FUNCTION grac_practice.fn_asset_value_calc_method
(
    @config_id BIGINT,
    @method    NVARCHAR(30),   -- NULL = the configured method
    @c         INT,
    @i         INT,
    @a         INT
)
RETURNS TABLE
AS
RETURN
    SELECT x.raw_score AS RawScore, r.score AS AssetValueScore, b.category_label AS AssetValueCategory, b.band_id AS BandId
      FROM grac_practice.asset_valuation_config cfg
     CROSS APPLY (SELECT ISNULL(@method, cfg.valuation_method) AS method) m
     CROSS APPLY (SELECT CAST(CASE m.method
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
       AND m.method IN (N'MAXIMUM', N'WEIGHTED_AVERAGE', N'SUMMATION')
       AND @c IS NOT NULL AND @i IS NOT NULL AND @a IS NOT NULL;
GO

-- 422 signature and columns unchanged; the formula now lives in fn_asset_value_calc_method.
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
    SELECT f.RawScore, f.AssetValueScore, f.AssetValueCategory, f.BandId
      FROM grac_practice.fn_asset_value_calc_method(@config_id, NULL, @c, @i, @a) f;
GO
PRINT '446: fn_asset_value_calc_method created; fn_asset_value_calc re-issued.';
GO

-- =====================================================================
-- 3. The Asset Value of each asset under the Active configuration now
--    (5.1.18.5.7: incomplete or failed calculations get a visible status
--    and no score), and how that compares with what is stored.
-- =====================================================================
CREATE OR ALTER FUNCTION grac_practice.fn_asset_valuation_eval (@organization_id BIGINT)
RETURNS TABLE
AS
RETURN
    SELECT a.asset_id AS AssetId, a.asset_name AS AssetName, cfg.config_id AS ConfigId, cfg.version_no AS ConfigVersionNo,
           v.c_text AS Confidentiality, v.i_text AS Integrity, v.a_text AS Availability,
           o.method_override AS MethodOverride, m.method_used AS MethodUsed, m.method_source AS MethodSource,
           k.RawScore, k.AssetValueScore, k.AssetValueCategory, k.BandId,
           s.status AS ValidationStatus, s.message AS ValidationMessage
      FROM grac_practice.organization_dependency_asset a
     OUTER APPLY (SELECT TOP (1) c.config_id, c.version_no, c.valuation_method, c.override_allowed,
                         c.weight_c + c.weight_i + c.weight_a AS weight_total
                    FROM grac_practice.asset_valuation_config c
                   WHERE c.organization_id = a.organization_id AND c.is_active_version = 1
                   ORDER BY c.config_id DESC) cfg
     OUTER APPLY (SELECT LEFT(MAX(CASE WHEN d.field_key = N'confidentiality_rating' THEN fv.value_text END), 40) AS c_text,
                         LEFT(MAX(CASE WHEN d.field_key = N'integrity_rating' THEN fv.value_text END), 40) AS i_text,
                         LEFT(MAX(CASE WHEN d.field_key = N'availability_rating' THEN fv.value_text END), 40) AS a_text,
                         LEFT(MAX(CASE WHEN d.field_key = N'asset_valuation_method' THEN fv.value_text END), 30) AS m_text
                    FROM grac_practice.asset_field_value fv
                    JOIN grac_practice.asset_field_definition d ON d.field_definition_id = fv.field_definition_id
                   WHERE fv.asset_id = a.asset_id
                     AND d.field_key IN (N'confidentiality_rating', N'integrity_rating', N'availability_rating', N'asset_valuation_method')) v
     CROSS APPLY (SELECT TRY_CONVERT(INT, v.c_text) AS c, TRY_CONVERT(INT, v.i_text) AS i, TRY_CONVERT(INT, v.a_text) AS av,
                         CASE WHEN EXISTS (SELECT 1 FROM grac_practice.asset_cia_scale_level l
                                            WHERE l.config_id = cfg.config_id AND l.dimension_code = N'C'
                                              AND CAST(l.score AS NVARCHAR(40)) = v.c_text) THEN 1 ELSE 0 END AS c_ok,
                         CASE WHEN EXISTS (SELECT 1 FROM grac_practice.asset_cia_scale_level l
                                            WHERE l.config_id = cfg.config_id AND l.dimension_code = N'I'
                                              AND CAST(l.score AS NVARCHAR(40)) = v.i_text) THEN 1 ELSE 0 END AS i_ok,
                         CASE WHEN EXISTS (SELECT 1 FROM grac_practice.asset_cia_scale_level l
                                            WHERE l.config_id = cfg.config_id AND l.dimension_code = N'A'
                                              AND CAST(l.score AS NVARCHAR(40)) = v.a_text) THEN 1 ELSE 0 END AS a_ok) n
     -- An override is a recorded method that differs from the configured one (D133).
     CROSS APPLY (SELECT CASE WHEN v.m_text IN (N'MAXIMUM', N'WEIGHTED_AVERAGE', N'SUMMATION')
                               AND v.m_text <> cfg.valuation_method THEN v.m_text END AS method_override) o
     CROSS APPLY (SELECT CASE WHEN o.method_override IS NOT NULL AND cfg.override_allowed = 1 THEN o.method_override
                              ELSE cfg.valuation_method END AS method_used,
                         CASE WHEN cfg.config_id IS NULL THEN NULL
                              WHEN o.method_override IS NOT NULL AND cfg.override_allowed = 1 THEN N'OVERRIDE'
                              ELSE N'CONFIG' END AS method_source) m
     OUTER APPLY (SELECT f.RawScore, f.AssetValueScore, f.AssetValueCategory, f.BandId
                    FROM grac_practice.fn_asset_value_calc_method(cfg.config_id, m.method_used, n.c, n.i, n.av) f
                   WHERE n.c_ok = 1 AND n.i_ok = 1 AND n.a_ok = 1
                     AND NOT (m.method_used = N'WEIGHTED_AVERAGE' AND cfg.weight_total <> 100)) k
     CROSS APPLY (SELECT CASE
                    WHEN v.c_text IS NULL AND v.i_text IS NULL AND v.a_text IS NULL THEN N'NOT_RATED'
                    WHEN cfg.config_id IS NULL THEN N'INVALID'
                    WHEN v.c_text IS NULL OR v.i_text IS NULL OR v.a_text IS NULL THEN N'INCOMPLETE'
                    WHEN n.c_ok = 0 OR n.i_ok = 0 OR n.a_ok = 0 THEN N'INVALID'
                    WHEN m.method_used = N'WEIGHTED_AVERAGE' AND cfg.weight_total <> 100 THEN N'INVALID'
                    WHEN k.AssetValueCategory IS NULL THEN N'INVALID'
                    ELSE N'VALID' END AS status,
                  CASE
                    WHEN v.c_text IS NULL AND v.i_text IS NULL AND v.a_text IS NULL THEN NULL
                    WHEN cfg.config_id IS NULL THEN N'There is no Active valuation configuration, so Asset Value cannot be calculated.'
                    WHEN v.c_text IS NULL OR v.i_text IS NULL OR v.a_text IS NULL
                        THEN CONCAT(N'Rating missing: ', CONCAT_WS(N', ',
                                 CASE WHEN v.c_text IS NULL THEN N'Confidentiality' END,
                                 CASE WHEN v.i_text IS NULL THEN N'Integrity' END,
                                 CASE WHEN v.a_text IS NULL THEN N'Availability' END), N'.')
                    WHEN n.c_ok = 0 OR n.i_ok = 0 OR n.a_ok = 0
                        THEN CONCAT(N'Not on the CIA scale of configuration version ', cfg.version_no, N': ', CONCAT_WS(N', ',
                                 CASE WHEN n.c_ok = 0 THEN CONCAT(N'Confidentiality ', v.c_text) END,
                                 CASE WHEN n.i_ok = 0 THEN CONCAT(N'Integrity ', v.i_text) END,
                                 CASE WHEN n.a_ok = 0 THEN CONCAT(N'Availability ', v.a_text) END), N'.')
                    WHEN m.method_used = N'WEIGHTED_AVERAGE' AND cfg.weight_total <> 100
                        THEN CONCAT(N'The Weighted Average weights of configuration version ', cfg.version_no,
                                    N' total ', cfg.weight_total, N' percent, not 100.')
                    WHEN k.AssetValueCategory IS NULL
                        THEN CONCAT(N'No value band of configuration version ', cfg.version_no, N' covers the score ',
                                    k.AssetValueScore, N' (', m.method_used, N').')
                    WHEN o.method_override IS NOT NULL AND cfg.override_allowed = 0
                        THEN CONCAT(N'The asset-level method ', o.method_override, N' is recorded, but configuration version ',
                                    cfg.version_no, N' does not permit overrides; the configured method is used.')
                    ELSE NULL END AS message) s
     WHERE a.organization_id = @organization_id AND a.merged_into_asset_id IS NULL;
GO

CREATE OR ALTER FUNCTION grac_practice.fn_asset_valuation_state (@organization_id BIGINT)
RETURNS TABLE
AS
RETURN
    SELECT e.AssetId, e.AssetName, e.ConfigId, e.ConfigVersionNo, e.Confidentiality, e.Integrity, e.Availability,
           e.MethodOverride, e.MethodUsed, e.MethodSource, e.RawScore, e.AssetValueScore, e.AssetValueCategory, e.BandId,
           e.ValidationStatus, e.ValidationMessage,
           r.config_id AS StoredConfigId, r.config_version_no AS StoredConfigVersionNo,
           r.confidentiality AS StoredConfidentiality, r.integrity AS StoredIntegrity, r.availability AS StoredAvailability,
           r.method_used AS StoredMethodUsed, r.method_source AS StoredMethodSource,
           r.asset_value_score AS StoredScore, r.asset_value_category AS StoredCategory,
           r.validation_status AS StoredStatus, r.validation_message AS StoredMessage,
           r.source AS StoredSource, r.calculated_by AS CalculatedBy, r.calculated_dt AS CalculatedDt,
           x.not_calculated AS NotCalculated, x.config_changed AS ConfigChanged, x.values_changed AS ValuesChanged,
           CASE WHEN x.not_calculated = 1 THEN N'NOT_CALCULATED'
                WHEN x.config_changed = 1 AND x.values_changed = 1 THEN N'CONFIG_AND_VALUES'
                WHEN x.config_changed = 1 THEN N'CONFIG_CHANGED'
                WHEN x.values_changed = 1 THEN N'VALUES_CHANGED'
                ELSE N'CURRENT' END AS StateCode,
           CASE WHEN x.not_calculated = 0 AND x.config_changed = 0 AND x.values_changed = 0 THEN 1 ELSE 0 END AS IsCurrent
      FROM grac_practice.fn_asset_valuation_eval(@organization_id) e
      LEFT JOIN grac_practice.asset_valuation_result r ON r.asset_id = e.AssetId
     CROSS APPLY (SELECT
            CASE WHEN r.asset_id IS NULL AND e.ValidationStatus <> N'NOT_RATED' THEN 1 ELSE 0 END AS not_calculated,
            -- A new Active version (or none) -- not for assets that are unrated either way.
            CASE WHEN r.asset_id IS NOT NULL AND ISNULL(r.config_id, -1) <> ISNULL(e.ConfigId, -1)
                      AND NOT (r.validation_status = N'NOT_RATED' AND e.ValidationStatus = N'NOT_RATED') THEN 1 ELSE 0 END AS config_changed,
            -- Ratings or method changed by the form, a merge, a split or discovery.
            CASE WHEN r.asset_id IS NOT NULL
                      AND (   ISNULL(r.confidentiality, N'') <> ISNULL(e.Confidentiality, N'')
                           OR ISNULL(r.integrity, N'') <> ISNULL(e.Integrity, N'')
                           OR ISNULL(r.availability, N'') <> ISNULL(e.Availability, N'')
                           OR ISNULL(r.method_override, N'') <> ISNULL(e.MethodOverride, N'')) THEN 1 ELSE 0 END AS values_changed) x;
GO

-- Risks linked to an asset (265 risk_dependency_map, category Asset -- as 443).
CREATE OR ALTER FUNCTION grac_practice.fn_asset_valuation_risk_links (@organization_id BIGINT)
RETURNS TABLE
AS
RETURN
    SELECT m.dependency_object_id AS AssetId, COUNT(DISTINCT m.risk_register_id) AS RiskCount
      FROM grac_practice.risk_dependency_map m
      JOIN grac_practice.dependency_type_master dt ON dt.dependency_type_id = m.dependency_type_id
                                                  AND (dt.dependency_type_code = N'ASSET' OR dt.dependency_type_name = N'Asset')
     WHERE m.organization_id = @organization_id
     GROUP BY m.dependency_object_id;
GO
PRINT '446: valuation evaluation, state and risk-link functions created.';
GO

-- =====================================================================
-- 4. Store a calculation (history + current result). Never raises for an
--    asset it cannot see (merged-away assets have no Asset Value), so the
--    asset form save and the scheduler are not blocked by it.
--      AUTO        applies when the ratings or method changed, or nothing
--                  was stored yet (5.1.18.5.7 "saving valid CIA ratings
--                  shall automatically calculate"); a new configuration
--                  version alone waits for a controlled recalculation
--                  (5.1.18.5.6 / 5.1.18.5.9 "not silently changed").
--      CONTROLLED  applies any difference (recalculation run, single
--                  asset, method override).
--    @out_status: NOT_RATED / INCOMPLETE / INVALID / VALID, or OUT_OF_DATE
--    when AUTO left a configuration change for the controlled run.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_valuation_apply
    @organization_id   BIGINT,
    @asset_id          BIGINT,
    @mode              NVARCHAR(12)   = N'AUTO',
    @source            NVARCHAR(30)   = N'FORM',
    @reason_text       NVARCHAR(1000) = NULL,
    @run_id            BIGINT         = NULL,
    @actor_employee_id BIGINT         = NULL,
    @actor             NVARCHAR(100)  = N'system',
    @out_status        NVARCHAR(20)   = NULL OUTPUT,
    @out_message       NVARCHAR(500)  = NULL OUTPUT,
    @out_changed       BIT            = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    SET @mode = CASE WHEN UPPER(ISNULL(@mode, N'')) = N'CONTROLLED' THEN N'CONTROLLED' ELSE N'AUTO' END;
    SET @reason_text = NULLIF(LTRIM(RTRIM(@reason_text)), N'');
    SELECT @out_status = NULL, @out_message = NULL, @out_changed = 0;

    DECLARE @found BIT = 0, @is_current BIT, @not_calc BIT, @cfg_changed BIT, @val_changed BIT,
            @cfg BIGINT, @ver INT, @c NVARCHAR(40), @i NVARCHAR(40), @a NVARCHAR(40),
            @ovr NVARCHAR(30), @mused NVARCHAR(30), @msrc NVARCHAR(10),
            @raw DECIMAL(18, 6), @score DECIMAL(18, 4), @cat NVARCHAR(100), @band BIGINT,
            @status NVARCHAR(20), @msg NVARCHAR(500),
            @p_cfg BIGINT, @p_ver INT, @p_c NVARCHAR(40), @p_i NVARCHAR(40), @p_a NVARCHAR(40), @p_mused NVARCHAR(30),
            @p_score DECIMAL(18, 4), @p_cat NVARCHAR(100), @p_status NVARCHAR(20), @p_msg NVARCHAR(500);
    SELECT @found = 1, @is_current = s.IsCurrent, @not_calc = s.NotCalculated, @cfg_changed = s.ConfigChanged,
           @val_changed = s.ValuesChanged, @cfg = s.ConfigId, @ver = s.ConfigVersionNo,
           @c = s.Confidentiality, @i = s.Integrity, @a = s.Availability,
           @ovr = s.MethodOverride, @mused = s.MethodUsed, @msrc = s.MethodSource,
           @raw = s.RawScore, @score = s.AssetValueScore, @cat = s.AssetValueCategory, @band = s.BandId,
           @status = s.ValidationStatus, @msg = s.ValidationMessage,
           @p_cfg = s.StoredConfigId, @p_ver = s.StoredConfigVersionNo, @p_c = s.StoredConfidentiality,
           @p_i = s.StoredIntegrity, @p_a = s.StoredAvailability, @p_mused = s.StoredMethodUsed,
           @p_score = s.StoredScore, @p_cat = s.StoredCategory, @p_status = s.StoredStatus, @p_msg = s.StoredMessage
      FROM grac_practice.fn_asset_valuation_state(@organization_id) s
     WHERE s.AssetId = @asset_id;
    IF @found = 0 RETURN;

    IF @is_current = 1 OR (@mode = N'AUTO' AND @not_calc = 0 AND @val_changed = 0)
    BEGIN
        IF @is_current = 1
        BEGIN
            SELECT @out_status = ISNULL(@p_status, @status), @out_message = CASE WHEN @p_status IS NULL THEN @msg ELSE @p_msg END;
        END
        ELSE
        BEGIN
            SELECT @out_status = N'OUT_OF_DATE',
                   @out_message = CONCAT(N'Asset Value was calculated with valuation configuration version ',
                                         ISNULL(CAST(@p_ver AS NVARCHAR(12)), N'(none)'), N'; the Active version is ',
                                         ISNULL(CAST(@ver AS NVARCHAR(12)), N'(none)'),
                                         N'. It changes with a controlled recalculation (Asset Valuation, Recalculation tab).');
        END
        RETURN;
    END

    -- Only a VALID calculation keeps a score and category (5.1.18.5.7).
    DECLARE @keep BIT = CASE WHEN @status = N'VALID' THEN 1 ELSE 0 END, @hist BIGINT;
    BEGIN TRAN;
    INSERT grac_practice.asset_valuation_history
        (organization_id, asset_id, source, run_id, reason_text,
         prev_config_id, prev_config_version, prev_confidentiality, prev_integrity, prev_availability, prev_method_used,
         prev_score, prev_category, prev_status,
         new_config_id, new_config_version, confidentiality, integrity, availability, method_override, method_used, method_source,
         raw_score, new_score, new_category, new_band_id, new_status, message, actor_employee_id, entered_by)
    VALUES (@organization_id, @asset_id, @source, @run_id, @reason_text,
            @p_cfg, @p_ver, @p_c, @p_i, @p_a, @p_mused, @p_score, @p_cat, @p_status,
            @cfg, @ver, @c, @i, @a, @ovr, @mused, @msrc,
            @raw, CASE WHEN @keep = 1 THEN @score END, CASE WHEN @keep = 1 THEN @cat END, CASE WHEN @keep = 1 THEN @band END,
            @status, @msg, @actor_employee_id, @actor);
    SET @hist = SCOPE_IDENTITY();

    MERGE grac_practice.asset_valuation_result AS t
    USING (SELECT @asset_id AS asset_id) AS src
       ON t.asset_id = src.asset_id
    WHEN MATCHED THEN
        UPDATE SET config_id = @cfg, config_version_no = @ver, confidentiality = @c, integrity = @i, availability = @a,
                   method_override = @ovr, method_used = @mused, method_source = @msrc, raw_score = @raw,
                   asset_value_score = CASE WHEN @keep = 1 THEN @score END,
                   asset_value_category = CASE WHEN @keep = 1 THEN @cat END,
                   band_id = CASE WHEN @keep = 1 THEN @band END,
                   validation_status = @status, validation_message = @msg, source = @source, run_id = @run_id,
                   last_history_id = @hist, calculated_by = @actor, calculated_dt = SYSUTCDATETIME()
    WHEN NOT MATCHED BY TARGET THEN
        INSERT (asset_id, organization_id, config_id, config_version_no, confidentiality, integrity, availability,
                method_override, method_used, method_source, raw_score, asset_value_score, asset_value_category, band_id,
                validation_status, validation_message, source, run_id, last_history_id, calculated_by)
        VALUES (@asset_id, @organization_id, @cfg, @ver, @c, @i, @a, @ovr, @mused, @msrc, @raw,
                CASE WHEN @keep = 1 THEN @score END, CASE WHEN @keep = 1 THEN @cat END, CASE WHEN @keep = 1 THEN @band END,
                @status, @msg, @source, @run_id, @hist, @actor);
    COMMIT;

    SELECT @out_status = @status, @out_message = @msg, @out_changed = 1;
END
GO

-- Scheduler step: AUTO recalculation for ratings changed outside the asset
-- form (merge, split, discovery) and first calculations (D137).
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_valuation_sync
    @organization_id BIGINT,
    @actor           NVARCHAR(100) = N'scheduler',
    @updated         INT           = NULL OUTPUT,
    @errors          INT           = NULL OUTPUT,
    @error_text      NVARCHAR(MAX) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT OFF;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'scheduler');
    SELECT @updated = 0, @errors = 0, @error_text = NULL;

    DECLARE @list TABLE (asset_id BIGINT NOT NULL PRIMARY KEY);
    INSERT @list (asset_id)
    SELECT s.AssetId FROM grac_practice.fn_asset_valuation_state(@organization_id) s
     WHERE s.NotCalculated = 1 OR s.ValuesChanged = 1;

    DECLARE @aid BIGINT, @st NVARCHAR(20), @ms NVARCHAR(500), @ch BIT;
    DECLARE val_cur CURSOR LOCAL STATIC FOR SELECT asset_id FROM @list ORDER BY asset_id;
    OPEN val_cur;
    FETCH NEXT FROM val_cur INTO @aid;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            SET @ch = 0;
            EXEC grac_practice.sp_asset_valuation_apply
                 @organization_id = @organization_id, @asset_id = @aid, @mode = N'AUTO', @source = N'SCHEDULER',
                 @actor = @actor, @out_status = @st OUTPUT, @out_message = @ms OUTPUT, @out_changed = @ch OUTPUT;
            IF @ch = 1 SET @updated = @updated + 1;
        END TRY
        BEGIN CATCH
            IF XACT_STATE() <> 0 ROLLBACK;
            SET @errors = @errors + 1;
            SET @error_text = LEFT(CONCAT(@error_text, CASE WHEN @error_text IS NULL THEN N'' ELSE CHAR(10) END,
                                          N'Asset ', @aid, N' (asset value): ', ERROR_MESSAGE()), 4000);
        END CATCH
        FETCH NEXT FROM val_cur INTO @aid;
    END
    CLOSE val_cur;
    DEALLOCATE val_cur;
END
GO
PRINT '446: sp_asset_valuation_apply and sp_asset_valuation_sync created.';
GO

-- =====================================================================
-- 5. Asset-level method override (5.1.18.5.3: disabled by default; an
--    authorized role and a reason when enabled -- the Web proxy requires
--    asset-register APPROVE). NULL or the configured method removes the
--    override. Stored as the Asset Valuation Method field value of the asset.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_valuation_method_set
    @organization_id   BIGINT,
    @asset_id          BIGINT,
    @method            NVARCHAR(30)   = NULL,
    @reason_text       NVARCHAR(1000) = NULL,
    @actor_employee_id BIGINT         = NULL,
    @actor             NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    SET @method = NULLIF(UPPER(LTRIM(RTRIM(@method))), N'');
    SET @reason_text = NULLIF(LTRIM(RTRIM(@reason_text)), N'');

    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization_dependency_asset
                    WHERE asset_id = @asset_id AND organization_id = @organization_id AND merged_into_asset_id IS NULL)
        THROW 53000, 'Asset not found for this organization.', 1;
    DECLARE @cfg_method NVARCHAR(30), @allowed BIT;
    SELECT TOP (1) @cfg_method = valuation_method, @allowed = override_allowed
      FROM grac_practice.asset_valuation_config
     WHERE organization_id = @organization_id AND is_active_version = 1
     ORDER BY config_id DESC;
    IF @cfg_method IS NULL
        THROW 53001, 'There is no Active valuation configuration. Activate one on Asset Valuation first.', 1;
    IF @method IS NOT NULL AND @method NOT IN (N'MAXIMUM', N'WEIGHTED_AVERAGE', N'SUMMATION')
        THROW 53002, 'Choose Maximum, Weighted Average or Summation.', 1;
    IF @method = @cfg_method SET @method = NULL;
    IF @method IS NOT NULL AND @allowed = 0
        THROW 53003, 'Asset-level method override is not enabled in the Active valuation configuration.', 1;
    IF @reason_text IS NULL
        THROW 53004, 'A reason is required.', 1;

    DECLARE @def INT = (SELECT field_definition_id FROM grac_practice.asset_field_definition WHERE field_key = N'asset_valuation_method');
    DECLARE @before NVARCHAR(30) = (SELECT LEFT(value_text, 30) FROM grac_practice.asset_field_value
                                     WHERE asset_id = @asset_id AND field_definition_id = @def);
    DECLARE @st NVARCHAR(20), @ms NVARCHAR(500), @ch BIT, @src NVARCHAR(30) = N'METHOD_OVERRIDE';

    BEGIN TRAN;
    IF @method IS NULL
    BEGIN
        DELETE FROM grac_practice.asset_field_value WHERE asset_id = @asset_id AND field_definition_id = @def;
    END
    ELSE IF @before IS NULL
    BEGIN
        INSERT grac_practice.asset_field_value (asset_id, field_definition_id, value_text, entered_by)
        VALUES (@asset_id, @def, @method, @actor);
    END
    ELSE
    BEGIN
        UPDATE grac_practice.asset_field_value
           SET value_text = @method, value_number = NULL, value_date = NULL, value_ref = NULL,
               updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE asset_id = @asset_id AND field_definition_id = @def;
    END
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-valuation', @asset_id, N'METHOD_OVERRIDE',
            (SELECT @before AS methodOverride FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            (SELECT @method AS methodOverride, @cfg_method AS configuredMethod, @reason_text AS reason
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            N'Active', @actor);
    EXEC grac_practice.sp_asset_valuation_apply
         @organization_id = @organization_id, @asset_id = @asset_id, @mode = N'CONTROLLED', @source = @src,
         @reason_text = @reason_text, @actor_employee_id = @actor_employee_id, @actor = @actor,
         @out_status = @st OUTPUT, @out_message = @ms OUTPUT, @out_changed = @ch OUTPUT;
    COMMIT;

    SELECT @asset_id AS AssetId, N'SAVED' AS Result, @st AS ValidationStatus, @ms AS ValidationMessage, @ch AS Changed;
END
GO

-- One asset, now (D138). Moving an asset to a newer configuration version
-- needs a reason; a ratings change does not.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_valuation_recalculate
    @organization_id   BIGINT,
    @asset_id          BIGINT,
    @reason_text       NVARCHAR(1000) = NULL,
    @actor_employee_id BIGINT         = NULL,
    @actor             NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    SET @reason_text = NULLIF(LTRIM(RTRIM(@reason_text)), N'');
    DECLARE @found BIT = 0, @cfg_changed BIT, @state NVARCHAR(30);
    SELECT @found = 1, @cfg_changed = s.ConfigChanged, @state = s.StateCode
      FROM grac_practice.fn_asset_valuation_state(@organization_id) s
     WHERE s.AssetId = @asset_id;
    IF @found = 0 THROW 53000, 'Asset not found for this organization.', 1;
    IF @cfg_changed = 1 AND @reason_text IS NULL
        THROW 53004, 'A reason is required to recalculate this asset with the Active configuration version.', 1;

    DECLARE @st NVARCHAR(20), @ms NVARCHAR(500), @ch BIT;
    BEGIN TRAN;
    EXEC grac_practice.sp_asset_valuation_apply
         @organization_id = @organization_id, @asset_id = @asset_id, @mode = N'CONTROLLED', @source = N'MANUAL',
         @reason_text = @reason_text, @actor_employee_id = @actor_employee_id, @actor = @actor,
         @out_status = @st OUTPUT, @out_message = @ms OUTPUT, @out_changed = @ch OUTPUT;
    IF @ch = 1
        INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
        VALUES (N'asset-valuation', @asset_id, N'RECALCULATE',
                (SELECT @state AS state FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
                (SELECT @st AS validationStatus, @reason_text AS reason FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
                N'Active', @actor);
    COMMIT;

    SELECT @asset_id AS AssetId, CASE WHEN @ch = 1 THEN N'RECALCULATED' ELSE N'UNCHANGED' END AS Result,
           @st AS ValidationStatus, @ms AS ValidationMessage, @ch AS Changed;
END
GO
PRINT '446: method override and single-asset recalculation created.';
GO

-- =====================================================================
-- 6. Controlled recalculation (5.1.18.5.7 / 5.1.18.5.8): impact analysis
--    first, then a run with a reason, against the count the preview showed.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_valuation_recalc_preview
    @organization_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 53007, 'Organization not found.', 1;

    SELECT s.AssetId, s.AssetName, s.StateCode, s.StoredConfigVersionNo, s.StoredScore, s.StoredCategory, s.StoredStatus,
           s.ConfigVersionNo, s.ValidationStatus, s.ValidationMessage,
           CASE WHEN s.ValidationStatus = N'VALID' THEN s.AssetValueScore END AS NewScore,
           CASE WHEN s.ValidationStatus = N'VALID' THEN s.AssetValueCategory END AS NewCategory
      INTO #aff
      FROM grac_practice.fn_asset_valuation_state(@organization_id) s
     WHERE s.IsCurrent = 0;

    -- 1. Summary
    SELECT c.config_id AS ActiveConfigId, c.version_no AS ActiveVersionNo, c.valuation_method AS ValuationMethod,
           c.override_allowed AS OverrideAllowed,
           (SELECT COUNT(*) FROM #aff) AS AffectedAssets,
           (SELECT COUNT(*) FROM #aff WHERE StateCode = N'NOT_CALCULATED') AS NotCalculated,
           (SELECT COUNT(*) FROM #aff WHERE StateCode IN (N'CONFIG_CHANGED', N'CONFIG_AND_VALUES')) AS ConfigChanged,
           (SELECT COUNT(*) FROM #aff WHERE StateCode = N'VALUES_CHANGED') AS ValuesChanged,
           (SELECT COUNT(*) FROM #aff WHERE ISNULL(StoredCategory, N'') <> ISNULL(NewCategory, N'')) AS CategoryChanges,
           (SELECT COUNT(*) FROM #aff WHERE ValidationStatus IN (N'INCOMPLETE', N'INVALID')) AS NotValidAfter,
           (SELECT COUNT(DISTINCT m.risk_register_id)
              FROM grac_practice.risk_dependency_map m
              JOIN grac_practice.dependency_type_master dt ON dt.dependency_type_id = m.dependency_type_id
                                                          AND (dt.dependency_type_code = N'ASSET' OR dt.dependency_type_name = N'Asset')
             WHERE m.organization_id = @organization_id
               AND m.dependency_object_id IN (SELECT AssetId FROM #aff)) AS LinkedRisks,
           (SELECT COUNT(*) FROM grac_practice.asset_valuation_result r
             WHERE r.organization_id = @organization_id AND r.validation_status = N'VALID') AS ValuedAssets,
           (SELECT COUNT(*) FROM grac_practice.asset_valuation_recalc_run r
             WHERE r.organization_id = @organization_id AND r.status = N'RUNNING') AS RunsInProgress
      FROM grac_practice.organization o
      LEFT JOIN grac_practice.asset_valuation_config c ON c.organization_id = o.organization_id AND c.is_active_version = 1
     WHERE o.organization_id = @organization_id;

    -- 2. Category moves
    SELECT StoredStatus AS FromStatus, StoredCategory AS FromCategory, ValidationStatus AS ToStatus, NewCategory AS ToCategory,
           COUNT(*) AS AssetCount
      FROM #aff
     GROUP BY StoredStatus, StoredCategory, ValidationStatus, NewCategory
     ORDER BY COUNT(*) DESC, StoredCategory, NewCategory;

    -- 3. Affected assets (first 500)
    SELECT TOP (500) f.AssetId, f.AssetName, f.StateCode, f.StoredConfigVersionNo, f.StoredScore, f.StoredCategory, f.StoredStatus,
           f.ConfigVersionNo, f.NewScore, f.NewCategory, f.ValidationStatus AS NewStatus, f.ValidationMessage AS Message,
           ISNULL(rl.RiskCount, 0) AS RiskCount
      FROM #aff f
      LEFT JOIN grac_practice.fn_asset_valuation_risk_links(@organization_id) rl ON rl.AssetId = f.AssetId
     ORDER BY CASE WHEN ISNULL(f.StoredCategory, N'') <> ISNULL(f.NewCategory, N'') THEN 0 ELSE 1 END, f.AssetName;

    -- 4. Recent runs
    SELECT TOP (20) r.run_id AS RunId, r.status AS Status, cv.version_no AS ConfigVersionNo, r.reason_text AS Reason,
           r.affected_count AS AffectedCount, r.updated_count AS UpdatedCount, r.error_count AS ErrorCount,
           r.error_text AS ErrorText, r.started_dt AS StartedDt, r.finished_dt AS FinishedDt, r.entered_by AS EnteredBy
      FROM grac_practice.asset_valuation_recalc_run r
      LEFT JOIN grac_practice.asset_valuation_config cv ON cv.config_id = r.config_id
     WHERE r.organization_id = @organization_id
     ORDER BY r.run_id DESC;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_asset_valuation_recalc_run
    @organization_id   BIGINT,
    @reason_text       NVARCHAR(1000) = NULL,
    @expected_affected INT            = NULL,
    @actor_employee_id BIGINT         = NULL,
    @actor             NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT OFF;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    SET @reason_text = NULLIF(LTRIM(RTRIM(@reason_text)), N'');
    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 53007, 'Organization not found.', 1;
    IF @reason_text IS NULL
        THROW 53004, 'A reason is required for a recalculation run.', 1;

    DECLARE @res NVARCHAR(255) = CONCAT(N'grac_practice.asset_valuation_recalc.', @organization_id), @lock INT;
    EXEC @lock = sp_getapplock @Resource = @res, @LockMode = N'Exclusive', @LockOwner = N'Session', @LockTimeout = 0;
    IF @lock < 0
        THROW 53006, 'Another recalculation run is in progress for this organization.', 1;

    DECLARE @run BIGINT, @n INT = 0, @updated INT = 0, @errors INT = 0, @err NVARCHAR(MAX) = NULL,
            @aid BIGINT, @st NVARCHAR(20), @ms NVARCHAR(500), @ch BIT, @cfg BIGINT, @msg NVARCHAR(400);
    DECLARE @list TABLE (asset_id BIGINT NOT NULL PRIMARY KEY);
    BEGIN TRY
        INSERT @list (asset_id)
        SELECT s.AssetId FROM grac_practice.fn_asset_valuation_state(@organization_id) s WHERE s.IsCurrent = 0;
        SET @n = (SELECT COUNT(*) FROM @list);
        IF @expected_affected IS NOT NULL AND @expected_affected <> @n
        BEGIN
            SET @msg = CONCAT(N'The affected assets changed since the preview (', @expected_affected, N' then, ', @n,
                              N' now). Review the impact again and rerun.');
            THROW 53005, @msg, 1;
        END
        SET @cfg = (SELECT TOP (1) config_id FROM grac_practice.asset_valuation_config
                     WHERE organization_id = @organization_id AND is_active_version = 1 ORDER BY config_id DESC);
        INSERT grac_practice.asset_valuation_recalc_run (organization_id, config_id, reason_text, affected_count, actor_employee_id, entered_by)
        VALUES (@organization_id, @cfg, @reason_text, @n, @actor_employee_id, @actor);
        SET @run = SCOPE_IDENTITY();

        DECLARE run_cur CURSOR LOCAL STATIC FOR SELECT asset_id FROM @list ORDER BY asset_id;
        OPEN run_cur;
        FETCH NEXT FROM run_cur INTO @aid;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            BEGIN TRY
                SET @ch = 0;
                EXEC grac_practice.sp_asset_valuation_apply
                     @organization_id = @organization_id, @asset_id = @aid, @mode = N'CONTROLLED', @source = N'RECALC_RUN',
                     @reason_text = @reason_text, @run_id = @run, @actor_employee_id = @actor_employee_id, @actor = @actor,
                     @out_status = @st OUTPUT, @out_message = @ms OUTPUT, @out_changed = @ch OUTPUT;
                IF @ch = 1 SET @updated = @updated + 1;
            END TRY
            BEGIN CATCH
                IF XACT_STATE() <> 0 ROLLBACK;
                SET @errors = @errors + 1;
                SET @err = LEFT(CONCAT(@err, CASE WHEN @err IS NULL THEN N'' ELSE CHAR(10) END,
                                       N'Asset ', @aid, N': ', ERROR_MESSAGE()), 4000);
            END CATCH
            FETCH NEXT FROM run_cur INTO @aid;
        END
        CLOSE run_cur;
        DEALLOCATE run_cur;

        UPDATE grac_practice.asset_valuation_recalc_run
           SET status = CASE WHEN @errors > 0 THEN N'COMPLETED_WITH_ERRORS' ELSE N'COMPLETED' END,
               updated_count = @updated, error_count = @errors, error_text = @err, finished_dt = SYSUTCDATETIME()
         WHERE run_id = @run;
        INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
        VALUES (N'asset-valuation-run', @run, N'RECALCULATE', NULL,
                (SELECT @cfg AS configId, @n AS affected, @updated AS updated, @errors AS errors, @reason_text AS reason
                    FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
                N'Active', @actor);
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK;
        IF CURSOR_STATUS('local', 'run_cur') >= -1
        BEGIN
            IF CURSOR_STATUS('local', 'run_cur') >= 0 CLOSE run_cur;
            DEALLOCATE run_cur;
        END
        EXEC sp_releaseapplock @Resource = @res, @LockOwner = N'Session';
        IF @run IS NOT NULL
            UPDATE grac_practice.asset_valuation_recalc_run
               SET status = N'FAILED', updated_count = @updated, error_count = @errors + 1, finished_dt = SYSUTCDATETIME(),
                   error_text = LEFT(CONCAT(@err, CASE WHEN @err IS NULL THEN N'' ELSE CHAR(10) END, ERROR_MESSAGE()), 4000)
             WHERE run_id = @run;
        THROW;
    END CATCH
    EXEC sp_releaseapplock @Resource = @res, @LockOwner = N'Session';

    SELECT r.run_id AS RunId, r.status AS Result, r.affected_count AS AffectedCount, r.updated_count AS UpdatedCount,
           r.error_count AS ErrorCount, r.error_text AS ErrorText
      FROM grac_practice.asset_valuation_recalc_run r WHERE r.run_id = @run;
END
GO

-- One asset: current value, state against the Active configuration, history.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_valuation_get
    @organization_id BIGINT,
    @asset_id        BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization_dependency_asset
                    WHERE asset_id = @asset_id AND organization_id = @organization_id AND merged_into_asset_id IS NULL)
        THROW 53000, 'Asset not found for this organization.', 1;

    -- 1. State
    SELECT s.AssetId, s.ConfigId, s.ConfigVersionNo, c.valuation_method AS ConfiguredMethod, c.override_allowed AS OverrideAllowed,
           s.Confidentiality, s.Integrity, s.Availability, s.MethodOverride, s.MethodUsed, s.MethodSource,
           CASE WHEN s.ValidationStatus = N'VALID' THEN s.AssetValueScore END AS AssetValueScore,
           CASE WHEN s.ValidationStatus = N'VALID' THEN s.AssetValueCategory END AS AssetValueCategory,
           s.ValidationStatus, s.ValidationMessage,
           s.StoredConfigId, s.StoredConfigVersionNo, s.StoredConfidentiality, s.StoredIntegrity, s.StoredAvailability, s.StoredMethodUsed, s.StoredMethodSource, s.StoredScore, s.StoredCategory,
           s.StoredStatus, s.StoredMessage, s.StoredSource, s.CalculatedBy, s.CalculatedDt,
           s.StateCode, s.IsCurrent, s.ConfigChanged, s.ValuesChanged, s.NotCalculated,
           b.treatment_guidance AS TreatmentGuidance
      FROM grac_practice.fn_asset_valuation_state(@organization_id) s
      LEFT JOIN grac_practice.asset_valuation_config c ON c.config_id = s.ConfigId
      LEFT JOIN grac_practice.asset_valuation_result r ON r.asset_id = s.AssetId
      LEFT JOIN grac_practice.asset_value_band b ON b.band_id = r.band_id
     WHERE s.AssetId = @asset_id;

    -- 2. History (newest first)
    SELECT TOP (100) h.history_id AS HistoryId, h.source AS Source, h.run_id AS RunId, h.reason_text AS Reason,
           h.prev_config_version AS PrevConfigVersionNo, h.prev_confidentiality AS PrevConfidentiality,
           h.prev_integrity AS PrevIntegrity, h.prev_availability AS PrevAvailability, h.prev_method_used AS PrevMethodUsed,
           h.prev_score AS PrevScore, h.prev_category AS PrevCategory, h.prev_status AS PrevStatus,
           h.new_config_version AS ConfigVersionNo, h.confidentiality AS Confidentiality, h.integrity AS Integrity,
           h.availability AS Availability, h.method_used AS MethodUsed, h.method_source AS MethodSource,
           h.new_score AS Score, h.new_category AS Category, h.new_status AS Status, h.message AS Message,
           h.entered_by AS EnteredBy, h.entered_dt AS EnteredDt
      FROM grac_practice.asset_valuation_history h
     WHERE h.asset_id = @asset_id AND h.organization_id = @organization_id
     ORDER BY h.history_id DESC;
END
GO
PRINT '446: recalculation preview / run and asset valuation reader created.';
GO

-- =====================================================================
-- 7. Re-issued bodies (446 lines marked; otherwise unchanged)
-- =====================================================================
-- 435 body: method override rule, no template default for the method,
-- Asset Value recalculated after the save and reported as a warning.
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
    -- 446: the valuation method comes from the valuation configuration, not a template default (D134).
    IF @asset_id IS NULL                                                                       -- 446
        DELETE s FROM @sub s                                                                   -- 446
         WHERE s.field_key = N'asset_valuation_method'                                         -- 446
           AND NOT EXISTS (SELECT 1 FROM OPENJSON(@values_json) j                              -- 446
                            WHERE j.[key] COLLATE DATABASE_DEFAULT = N'asset_valuation_method'); -- 446

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
           CONCAT(N'"', t.label, N'" has a value that is not in its list: ', x.elem, N'.')   -- 435: MASTER:CONTRACT is a list now
      FROM @elems x JOIN @tf t ON t.field_key = x.field_key
     WHERE t.lookup_source NOT IN (N'MASTER:COUNTRY', N'MASTER:CURRENCY')
       AND t.lookup_source NOT LIKE N'STATE:%'
       AND NOT (t.lookup_source LIKE N'OPTION:%' AND EXISTS (
                SELECT 1 FROM grac_practice.fn_asset_field_options(@organization_id) o
                 WHERE o.OptionGroup = N'asset_field.' + SUBSTRING(t.lookup_source, 8, 100) AND o.OptionValue = x.elem))
       AND NOT (t.lookup_source LIKE N'MASTER:%' AND EXISTS (
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

    -- 435: coverage (5.1.11 / 5.2.14) -- warnings; a Lifecycle tab move to Active can be blocked (D42).
    DECLARE @psc BIGINT = TRY_CONVERT(BIGINT, (SELECT val FROM @eff WHERE field_key = N'primary_support_contract'));
    IF @psc IS NOT NULL AND @asset_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM grac_practice.asset_contract_coverage cv
                         JOIN grac_practice.asset_contract_version v ON v.version_id = cv.version_id
                         JOIN grac_practice.entity_status_master s ON s.entity_status_id = v.current_status_id
                        WHERE cv.contract_id = @psc AND cv.asset_id = @asset_id
                          AND s.status_code IN (N'DRAFT', N'IN_REVIEW', N'PENDING_APPROVAL', N'APPROVED', N'ACTIVE'))
        INSERT @issues (severity, field_key, message)
        VALUES (N'WARNING', N'primary_support_contract', N'The selected contract does not list this asset in its coverage; add it on the contract (Contracts -> version -> Asset coverage).');
    IF @asset_id IS NOT NULL
    BEGIN
        INSERT @issues (severity, field_key, message)
        SELECT N'WARNING', NULL, g.Message FROM grac_practice.fn_asset_coverage_gaps(@organization_id) g WHERE g.AssetId = @asset_id;
    END
    ELSE
        INSERT @issues (severity, field_key, message)
        SELECT N'WARNING', NULL, CONCAT(N'Required ', ISNULL(o.OptionLabel, r.coverage_type),
                                        N' coverage is not mapped yet; map the asset on a contract after saving.')
          FROM grac_practice.asset_coverage_requirement r
         OUTER APPLY (SELECT TOP 1 f.OptionLabel FROM grac_practice.fn_asset_field_options(@organization_id) f
                       WHERE f.OptionGroup = N'asset_field.coverage_type' AND f.OptionValue = r.coverage_type) o
         WHERE r.organization_id = @organization_id AND r.asset_type_id = @asset_type_id AND r.requirement_level = N'REQUIRED';

    -- Asset name is unique in the organization (existing constraint uq_pm_org_asset_name).
    DECLARE @name NVARCHAR(220) = LEFT((SELECT val FROM @eff WHERE field_key = N'asset_name'), 220);
    IF @name IS NOT NULL AND EXISTS (SELECT 1 FROM grac_practice.organization_dependency_asset
                                      WHERE organization_id = @organization_id AND asset_name = @name AND asset_id <> ISNULL(@asset_id, -1))
        INSERT @issues (severity, field_key, message) VALUES (N'ERROR', N'asset_name', N'Another asset in this organization already has this name.');

    -- 446: Asset Valuation Method differing from the configured method is an
    -- 446: asset-level override -- set on the Valuation section, never by the form (D133).
    DECLARE @cfg_method NVARCHAR(30), @cfg_override BIT, @cfg_version INT;                       -- 446
    SELECT TOP (1) @cfg_method = valuation_method, @cfg_override = override_allowed, @cfg_version = version_no   -- 446
      FROM grac_practice.asset_valuation_config                                                 -- 446
     WHERE organization_id = @organization_id AND is_active_version = 1 ORDER BY config_id DESC; -- 446
    INSERT @issues (severity, field_key, message)                                               -- 446
    SELECT N'ERROR', e.field_key,                                                               -- 446
           CASE WHEN @cfg_method IS NULL                                                        -- 446
                THEN N'There is no Active valuation configuration; leave Asset Valuation Method empty.'   -- 446
                WHEN @cfg_override = 0                                                          -- 446
                THEN CONCAT(N'Valuation configuration version ', @cfg_version, N' uses ', @cfg_method,   -- 446
                            N' and does not permit an asset-level method override; leave the field empty.')   -- 446
                ELSE N'An asset-level method override needs an approver and a reason: use Override method in the Valuation section.' END   -- 446
      FROM @eff e                                                                               -- 446
     WHERE e.field_key = N'asset_valuation_method' AND e.submitted = 1 AND e.val IS NOT NULL    -- 446
       AND e.val <> ISNULL(@cfg_method, N'');                                                   -- 446

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

    -- 431: ownership / custody / location history and the acknowledgement it raises (5.3.2).
    DECLARE @assign_source NVARCHAR(100) = N'Asset form';
    EXEC grac_practice.sp_asset_assignment_snapshot
         @organization_id = @organization_id, @asset_id = @out_asset_id, @source = @assign_source,
         @raise_acknowledgement = 1, @actor = @actor;

    -- 446: Asset Value (5.1.18.5.7) -- recalculated when the ratings or method changed.
    DECLARE @val_status NVARCHAR(20), @val_message NVARCHAR(500), @val_changed BIT;          -- 446
    EXEC grac_practice.sp_asset_valuation_apply                                                -- 446
         @organization_id = @organization_id, @asset_id = @out_asset_id, @mode = N'AUTO', @source = N'FORM',   -- 446
         @actor_employee_id = @actor_employee_id, @actor = @actor,                             -- 446
         @out_status = @val_status OUTPUT, @out_message = @val_message OUTPUT, @out_changed = @val_changed OUTPUT;   -- 446

    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-register', @out_asset_id, CASE WHEN @asset_id IS NULL THEN N'ADD' ELSE N'SAVE' END,
            CASE WHEN @asset_id IS NULL THEN NULL ELSE @before END,
            (SELECT @template_id AS templateId,
                    (SELECT e.field_key AS fieldKey, e.val AS value FROM @eff e WHERE e.submitted = 1 FOR JSON PATH) AS changedValues
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            N'Active', @actor);
    COMMIT;

    IF @val_status IN (N'INCOMPLETE', N'INVALID', N'OUT_OF_DATE')                             -- 446
        INSERT @issues (severity, field_key, message)                                          -- 446
        VALUES (N'WARNING', NULL, LEFT(CONCAT(N'Asset Value: ', @val_message), 500));          -- 446
    SET @out_result = N'SAVED';
    SELECT severity AS Severity, field_key AS FieldKey, message AS Message FROM @issues ORDER BY field_key;
END
GO
PRINT '446: sp_asset_register_save re-issued.';
GO

-- 438 body: Asset Value sync step per organization.
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_scheduler_run
    @organization_id BIGINT        = NULL,
    @trigger_code    NVARCHAR(12)  = N'SCHEDULED',
    @actor           NVARCHAR(100) = N'scheduler'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT OFF;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'scheduler');
    SET @trigger_code = CASE WHEN UPPER(ISNULL(@trigger_code, N'')) = N'MANUAL' THEN N'MANUAL' ELSE N'SCHEDULED' END;
    IF @organization_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 54610, 'Organization not found.', 1;

    DECLARE @lock INT;
    EXEC @lock = sp_getapplock @Resource = N'grac_practice.asset_scheduler', @LockMode = N'Exclusive',
                               @LockOwner = N'Session', @LockTimeout = 0;
    IF @lock < 0
    BEGIN
        SELECT CAST(NULL AS BIGINT) AS RunId, N'SKIPPED' AS Result, 0 AS Organizations, 0 AS RenewalsStarted,
               0 AS AttestationsGenerated, 0 AS OccurrencesOpened, 0 AS OccurrencesClosed, 0 AS NotificationsQueued,
               0 AS ErrorCount, N'Another scheduler run is in progress.' AS ErrorText, 0 AS TasksCreated;
        RETURN;
    END

    DECLARE @run BIGINT, @today DATE = CAST(SYSUTCDATETIME() AS DATE);
    BEGIN TRY
    INSERT grac_practice.asset_scheduler_run (organization_id, trigger_code, entered_by) VALUES (@organization_id, @trigger_code, @actor);
    SET @run = SCOPE_IDENTITY();

    DECLARE @orgs INT = 0, @ren INT = 0, @att INT = 0, @opened INT = 0, @closed INT = 0, @queued INT = 0, @errors INT = 0,
            @err NVARCHAR(MAX) = NULL,
            @o INT, @c INT, @q INT, @e INT, @et NVARCHAR(MAX), @gen INT, @rid BIGINT,
            @tasks INT = 0, @t INT, @ao INT, @ac INT;                                      -- 438
    DECLARE @vu INT;                                                                       -- 446

    DECLARE @org_list TABLE (organization_id BIGINT NOT NULL PRIMARY KEY);
    INSERT @org_list (organization_id)
    SELECT o.organization_id
      FROM grac_practice.organization o
     WHERE (@organization_id IS NOT NULL AND o.organization_id = @organization_id)
        OR (@organization_id IS NULL
            AND (EXISTS (SELECT 1 FROM grac_practice.organization_dependency_asset a WHERE a.organization_id = o.organization_id)
                 OR EXISTS (SELECT 1 FROM grac_practice.asset_contract c WHERE c.organization_id = o.organization_id)));

    DECLARE @org BIGINT, @contract BIGINT;
    DECLARE org_cur CURSOR LOCAL STATIC FOR SELECT organization_id FROM @org_list ORDER BY organization_id;
    OPEN org_cur;
    FETCH NEXT FROM org_cur INTO @org;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @orgs = @orgs + 1;

        BEGIN TRY
            EXEC grac_practice.sp_asset_notification_defaults_ensure @organization_id = @org, @actor = @actor;
            EXEC grac_practice.sp_asset_contract_sync @organization_id = @org, @actor = @actor;
        END TRY
        BEGIN CATCH
            IF XACT_STATE() <> 0 ROLLBACK;
            SET @errors = @errors + 1;
            SET @err = LEFT(CONCAT(@err, CASE WHEN @err IS NULL THEN N'' ELSE CHAR(10) END,
                                   N'Organization ', @org, N' (defaults / contract dates): ', ERROR_MESSAGE()), 8000);
        END CATCH

        IF EXISTS (SELECT 1 FROM grac_practice.asset_attestation_profile WHERE organization_id = @org AND is_active = 1)
        BEGIN
        BEGIN TRY
            SET @gen = 0;
            EXEC grac_practice.sp_asset_attestation_generate @organization_id = @org, @campaign_type = N'PERIODIC', @actor = @actor,
                 @scheduled = 1, @suppress_result = 1, @out_generated = @gen OUTPUT;
            SET @att = @att + ISNULL(@gen, 0);
        END TRY
        BEGIN CATCH
            IF XACT_STATE() <> 0 ROLLBACK;
            SET @errors = @errors + 1;
            SET @err = LEFT(CONCAT(@err, CASE WHEN @err IS NULL THEN N'' ELSE CHAR(10) END,
                                   N'Organization ', @org, N' (periodic attestation): ', ERROR_MESSAGE()), 8000);
        END CATCH
        END

        -- d. Renewal occurrences whose reminder window has opened.
        DECLARE ren_cur CURSOR LOCAL STATIC FOR
            SELECT c.contract_id
              FROM grac_practice.asset_contract c
              JOIN grac_practice.asset_contract_version cv ON cv.version_id = c.current_version_id
             CROSS APPLY (SELECT MIN(v.d) AS d FROM (VALUES (cv.notice_date), (cv.decision_date), (cv.effective_end)) v(d)) t
             OUTER APPLY (SELECT ProfileId FROM grac_practice.fn_asset_ntf_profile_for(
                              c.organization_id, grac_practice.fn_asset_ntf_contract_activity(c.contract_type),
                              grac_practice.fn_asset_ntf_version_severity(cv.version_id), @today)) p
             OUTER APPLY (SELECT MAX(s.offset_days) AS lead_days FROM grac_practice.asset_notification_stage s
                           WHERE s.profile_id = p.ProfileId AND s.is_active = 1 AND s.stage_kind = N'REMINDER') w
             WHERE c.organization_id = @org AND c.contract_status IN (N'ACTIVE', N'APPROVED', N'EXPIRED')
               AND cv.version_type <> N'TERMINATION' AND t.d IS NOT NULL
               AND DATEADD(DAY, -ISNULL(w.lead_days, 0), t.d) <= @today
               AND NOT EXISTS (SELECT 1 FROM grac_practice.asset_contract_renewal r
                                WHERE r.contract_id = c.contract_id
                                  AND (r.is_open = 1 OR (r.prior_version_id = cv.version_id AND ISNULL(r.outcome, N'') <> N'CANCELLED')));
        OPEN ren_cur;
        FETCH NEXT FROM ren_cur INTO @contract;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            BEGIN TRY
                SET @rid = NULL;
                EXEC grac_practice.sp_asset_contract_renewal_start @organization_id = @org, @contract_id = @contract,
                     @renewal_type = N'RENEWAL', @notes = N'Started by the scheduler: the renewal reminder window opened.',
                     @actor_employee_id = NULL, @actor = @actor, @suppress_result = 1, @out_renewal_id = @rid OUTPUT;
                IF @rid IS NOT NULL SET @ren = @ren + 1;
            END TRY
            BEGIN CATCH
                IF XACT_STATE() <> 0 ROLLBACK;
                SET @errors = @errors + 1;
                SET @err = LEFT(CONCAT(@err, CASE WHEN @err IS NULL THEN N'' ELSE CHAR(10) END,
                                       N'Contract ', @contract, N' (renewal start): ', ERROR_MESSAGE()), 8000);
            END CATCH
            FETCH NEXT FROM ren_cur INTO @contract;
        END
        CLOSE ren_cur;
        DEALLOCATE ren_cur;

        -- 446: Asset Value for ratings changed outside the asset form (5.1.18.5.7, D137).
        BEGIN TRY                                                                          -- 446
            SELECT @vu = 0, @e = 0, @et = NULL;                                            -- 446
            EXEC grac_practice.sp_asset_valuation_sync @organization_id = @org, @actor = @actor,   -- 446
                 @updated = @vu OUTPUT, @errors = @e OUTPUT, @error_text = @et OUTPUT;     -- 446
            SET @errors = @errors + ISNULL(@e, 0);                                         -- 446
            IF @et IS NOT NULL                                                             -- 446
                SET @err = LEFT(CONCAT(@err, CASE WHEN @err IS NULL THEN N'' ELSE CHAR(10) END, N'Organization ', @org, N': ', @et), 8000);   -- 446
        END TRY                                                                            -- 446
        BEGIN CATCH                                                                        -- 446
            IF XACT_STATE() <> 0 ROLLBACK;                                                 -- 446
            SET @errors = @errors + 1;                                                     -- 446
            SET @err = LEFT(CONCAT(@err, CASE WHEN @err IS NULL THEN N'' ELSE CHAR(10) END,   -- 446
                                   N'Organization ', @org, N' (asset value): ', ERROR_MESSAGE()), 8000);   -- 446
        END CATCH                                                                          -- 446

        -- 438: recurring asset activities (before the sweep, so new occurrences notify).
        BEGIN TRY
            SELECT @t = 0, @ao = 0, @ac = 0, @e = 0, @et = NULL;
            EXEC grac_practice.sp_asset_activity_run @organization_id = @org, @actor = @actor,
                 @tasks = @t OUTPUT, @opened = @ao OUTPUT, @completed = @ac OUTPUT, @errors = @e OUTPUT, @error_text = @et OUTPUT;
            SELECT @tasks = @tasks + ISNULL(@t, 0), @errors = @errors + ISNULL(@e, 0);
            IF @et IS NOT NULL
                SET @err = LEFT(CONCAT(@err, CASE WHEN @err IS NULL THEN N'' ELSE CHAR(10) END, N'Organization ', @org, N': ', @et), 8000);
        END TRY
        BEGIN CATCH
            IF XACT_STATE() <> 0 ROLLBACK;
            SET @errors = @errors + 1;
            SET @err = LEFT(CONCAT(@err, CASE WHEN @err IS NULL THEN N'' ELSE CHAR(10) END,
                                   N'Organization ', @org, N' (activities): ', ERROR_MESSAGE()), 8000);
        END CATCH

        BEGIN TRY
            SELECT @o = 0, @c = 0, @q = 0, @e = 0, @et = NULL;
            EXEC grac_practice.sp_asset_notification_sweep @organization_id = @org, @actor = @actor,
                 @opened = @o OUTPUT, @closed = @c OUTPUT, @queued = @q OUTPUT, @errors = @e OUTPUT, @error_text = @et OUTPUT;
            SELECT @opened = @opened + @o, @closed = @closed + @c, @queued = @queued + @q, @errors = @errors + @e;
            IF @et IS NOT NULL
                SET @err = LEFT(CONCAT(@err, CASE WHEN @err IS NULL THEN N'' ELSE CHAR(10) END, N'Organization ', @org, N': ', @et), 8000);
        END TRY
        BEGIN CATCH
            IF XACT_STATE() <> 0 ROLLBACK;
            SET @errors = @errors + 1;
            SET @err = LEFT(CONCAT(@err, CASE WHEN @err IS NULL THEN N'' ELSE CHAR(10) END,
                                   N'Organization ', @org, N' (notifications): ', ERROR_MESSAGE()), 8000);
        END CATCH

        FETCH NEXT FROM org_cur INTO @org;
    END
    CLOSE org_cur;
    DEALLOCATE org_cur;

    UPDATE grac_practice.asset_scheduler_run
       SET finished_dt = SYSUTCDATETIME(), result = CASE WHEN @errors > 0 THEN N'COMPLETED_WITH_ERRORS' ELSE N'COMPLETED' END,
           organizations = @orgs, renewals_started = @ren, attestations_generated = @att, occurrences_opened = @opened,
           occurrences_closed = @closed, notifications_queued = @queued, error_count = @errors, error_text = @err,
           tasks_created = @tasks                                                          -- 438
     WHERE run_id = @run;
    END TRY
    BEGIN CATCH
        -- Never leave the lock behind on a pooled connection.
        IF XACT_STATE() <> 0 ROLLBACK;
        IF CURSOR_STATUS('local', 'org_cur') >= -1
        BEGIN
            IF CURSOR_STATUS('local', 'org_cur') >= 0 CLOSE org_cur;
            DEALLOCATE org_cur;
        END
        EXEC sp_releaseapplock @Resource = N'grac_practice.asset_scheduler', @LockOwner = N'Session';
        IF @run IS NOT NULL
            UPDATE grac_practice.asset_scheduler_run
               SET finished_dt = SYSUTCDATETIME(), result = N'FAILED', error_count = @errors + 1,
                   error_text = LEFT(CONCAT(@err, CASE WHEN @err IS NULL THEN N'' ELSE CHAR(10) END, ERROR_MESSAGE()), 8000)
             WHERE run_id = @run;
        THROW;
    END CATCH
    EXEC sp_releaseapplock @Resource = N'grac_practice.asset_scheduler', @LockOwner = N'Session';

    SELECT run_id AS RunId, result AS Result, organizations AS Organizations, renewals_started AS RenewalsStarted,
           attestations_generated AS AttestationsGenerated, occurrences_opened AS OccurrencesOpened,
           occurrences_closed AS OccurrencesClosed, notifications_queued AS NotificationsQueued,
           error_count AS ErrorCount, error_text AS ErrorText, tasks_created AS TasksCreated   -- 438
      FROM grac_practice.asset_scheduler_run WHERE run_id = @run;
END
GO
PRINT '446: sp_asset_scheduler_run re-issued.';
GO

-- 439 body: Asset Value Score / Category from the stored VALID result.
CREATE OR ALTER FUNCTION grac_practice.fn_asset_stored_values (@asset_id BIGINT)
RETURNS TABLE
AS
RETURN
    SELECT d.field_definition_id AS FieldDefinitionId, d.field_key AS FieldKey, c.val AS Value
      FROM grac_practice.organization_dependency_asset a
     CROSS APPLY (VALUES
        (N'asset_id',             CAST(a.asset_id AS NVARCHAR(MAX))),
        (N'asset_name',           CAST(a.asset_name AS NVARCHAR(MAX))),
        (N'asset_category_id',    CAST(a.asset_category_id AS NVARCHAR(MAX))),
        (N'asset_subcategory_id', CAST(a.asset_subcategory_id AS NVARCHAR(MAX))),
        (N'asset_type_id',        CAST(a.asset_type_id AS NVARCHAR(MAX))),
        (N'organization_id',      CAST(a.organization_id AS NVARCHAR(MAX))),
        (N'location_id',          CAST(a.location_id AS NVARCHAR(MAX))),
        (N'owner_id',             CAST(a.owner_id AS NVARCHAR(MAX))),
        (N'purchase_dt',          CONVERT(NVARCHAR(MAX), a.purchase_dt, 23)),
        (N'warranty_expiry_dt',   CONVERT(NVARCHAR(MAX), a.warranty_expiry_dt, 23)),
        (N'amc_expiry_dt',        CONVERT(NVARCHAR(MAX), a.amc_expiry_dt, 23)),
        (N'criticality_id',       CAST(a.criticality_id AS NVARCHAR(MAX))),
        (N'remarks',              CAST(a.remarks AS NVARCHAR(MAX))),
        (N'entered_by',           CAST(a.entered_by AS NVARCHAR(MAX))),
        (N'entered_dt',           CONVERT(NVARCHAR(MAX), a.entered_dt, 126)),
        (N'updated_by',           CAST(a.updated_by AS NVARCHAR(MAX))),
        (N'updated_dt',           CONVERT(NVARCHAR(MAX), a.updated_dt, 126))
     ) AS c(column_name, val)
      JOIN grac_practice.asset_field_definition d ON d.storage_kind = N'COLUMN' AND d.column_name = c.column_name
     WHERE a.asset_id = @asset_id AND c.val IS NOT NULL
    UNION ALL
    SELECT v.field_definition_id, d.field_key, v.value_text
      FROM grac_practice.asset_field_value v
      JOIN grac_practice.asset_field_definition d ON d.field_definition_id = v.field_definition_id
     WHERE v.asset_id = @asset_id
    UNION ALL
    SELECT d.field_definition_id, d.field_key, s.status_code
      FROM grac_practice.organization_dependency_asset a
      JOIN grac_practice.entity_status_master s ON s.entity_status_id = a.current_status_id
      JOIN grac_practice.asset_field_definition d ON d.field_key = N'asset_status'
     WHERE a.asset_id = @asset_id
    UNION ALL
    -- 435: the calculated coverage status (5.1.11).
    SELECT d.field_definition_id, d.field_key, cs.CoverageStatusLabel
      FROM grac_practice.organization_dependency_asset a
     CROSS APPLY grac_practice.fn_asset_coverage_summary(a.organization_id, a.asset_id) cs
      JOIN grac_practice.asset_field_definition d ON d.field_key = N'coverage_status'
     WHERE a.asset_id = @asset_id
    UNION ALL
    -- 438: next calibration / maintenance / inspection date and calibration /
    -- maintenance status from the activity schedule (5.1.7), unless a value
    -- is stored for the field.
    SELECT d.field_definition_id, d.field_key, x.val
      FROM grac_practice.asset_activity_schedule s
      JOIN grac_practice.asset_activity_template t ON t.template_code = s.template_code
     CROSS APPLY (VALUES
        (t.next_date_field_key, CONVERT(NVARCHAR(MAX), s.next_due_date, 23)),
        (t.status_field_key,
         CASE WHEN t.status_field_key = N'maintenance_status'
                   AND EXISTS (SELECT 1 FROM grac_practice.asset_activity_occurrence o
                                WHERE o.asset_id = s.asset_id AND o.template_code = s.template_code
                                  AND o.status = N'OPEN' AND o.task_id IS NOT NULL) THEN N'In Progress'
              WHEN t.status_field_key = N'maintenance_status' THEN
                   CASE s.status_code WHEN N'VALID' THEN N'Not Due' WHEN N'DUE_SOON' THEN N'Due Soon' WHEN N'OVERDUE' THEN N'Overdue'
                                      WHEN N'FAILED' THEN N'Overdue' END                                   -- 439
              ELSE CASE s.status_code WHEN N'VALID' THEN N'Valid' WHEN N'DUE_SOON' THEN N'Due Soon' WHEN N'OVERDUE' THEN N'Overdue'
                                      WHEN N'NOT_APPLICABLE' THEN N'N/A' WHEN N'FAILED' THEN N'Failed' END END)   -- 439: Failed
     ) AS x(field_key, val)
      JOIN grac_practice.asset_field_definition d ON d.field_key = x.field_key
     WHERE s.asset_id = @asset_id AND x.val IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM grac_practice.asset_field_value v
                        WHERE v.asset_id = @asset_id AND v.field_definition_id = d.field_definition_id)   -- 446: no semicolon
    UNION ALL                                                                                  -- 446
    -- 446: the stored VALID Asset Value (5.1.18.5.7; read-only, SYSTEM fields).
    SELECT d.field_definition_id, d.field_key, x.val                                           -- 446
      FROM grac_practice.asset_valuation_result r                                              -- 446
     CROSS APPLY (VALUES                                                                       -- 446
        (N'asset_value_score', REPLACE(RTRIM(REPLACE(REPLACE(RTRIM(REPLACE(                    -- 446
             CAST(r.asset_value_score AS NVARCHAR(40)), N'0', N' ')), N' ', N'0'), N'.', N' ')), N' ', N'.')),   -- 446
        (N'asset_value_category', CAST(r.asset_value_category AS NVARCHAR(MAX)))               -- 446
     ) AS x(field_key, val)                                                                    -- 446
      JOIN grac_practice.asset_field_definition d ON d.field_key = x.field_key AND d.storage_kind = N'SYSTEM'   -- 446
     WHERE r.asset_id = @asset_id AND r.validation_status = N'VALID' AND x.val IS NOT NULL;   -- 446
GO
PRINT '446: fn_asset_stored_values re-issued.';
GO

-- =====================================================================
-- 8. Verification
-- =====================================================================
SELECT '446-a objects' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.asset_valuation_result','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.asset_valuation_history','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.asset_valuation_recalc_run','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.fn_asset_value_calc_method') IS NOT NULL
             AND OBJECT_ID('grac_practice.fn_asset_valuation_eval') IS NOT NULL
             AND OBJECT_ID('grac_practice.fn_asset_valuation_state') IS NOT NULL
             AND OBJECT_ID('grac_practice.fn_asset_valuation_risk_links') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_asset_valuation_apply','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_asset_valuation_sync','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_asset_valuation_method_set','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_asset_valuation_recalculate','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_asset_valuation_recalc_preview','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_asset_valuation_recalc_run','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_asset_valuation_get','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;
SELECT '446-b re-issued bodies' AS Check_,
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.fn_asset_value_calc')) LIKE '%fn_asset_value_calc_method%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_asset_register_save')) LIKE '%sp_asset_valuation_apply%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_asset_scheduler_run')) LIKE '%sp_asset_valuation_sync%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.fn_asset_stored_values')) LIKE '%asset_valuation_result%'
            THEN 'PASS' ELSE 'FAIL' END AS Result;
-- The 422 calculator and the method function agree for every Active configuration (score 3 / 3 / 3).
SELECT '446-c one formula' AS Check_,
       CASE WHEN NOT EXISTS (
                SELECT 1 FROM grac_practice.asset_valuation_config c
                 CROSS APPLY grac_practice.fn_asset_value_calc(c.config_id, 3, 3, 3) a
                 CROSS APPLY grac_practice.fn_asset_value_calc_method(c.config_id, c.valuation_method, 3, 3, 3) b
                 WHERE c.is_active_version = 1
                   AND (a.AssetValueScore <> b.AssetValueScore OR ISNULL(a.AssetValueCategory, N'') <> ISNULL(b.AssetValueCategory, N'')))
            THEN 'PASS' ELSE 'FAIL' END AS Result;
-- The state function reads for every organization with assets (no runtime error).
SELECT '446-d state readable' AS Check_, COUNT(*) AS AssetsEvaluated, 'PASS' AS Result
  FROM grac_practice.organization o
 CROSS APPLY grac_practice.fn_asset_valuation_state(o.organization_id) s;
GO

/* =====================================================================
   UAT (run as a user with asset-register EDIT / APPROVE and
   asset-valuation-config VIEW / APPROVE)
   ---------------------------------------------------------------------
   1. Asset Valuation: an Active configuration (bands set). Asset
      Register: open an asset whose template has the CIA fields, set
      C / I / A, save -> the Valuation section shows score, category,
      configuration version, VALID; Asset Value Score / Category on the
      form are read-only and filled; history shows a FORM row.
   2. Clear one rating, save -> warning "Asset Value: Rating missing ...",
      status INCOMPLETE, no score or category.
   3. Change Asset Valuation Method on the form to a method other than
      the configured one -> ERROR (override not permitted / use Override
      method). With override_allowed on a new Active version, Override
      method (approver, reason) -> MethodSource OVERRIDE, history row
      METHOD_OVERRIDE; Remove override returns to the configured method.
   4. Activate a new configuration version with different bands -> the
      asset shows "Out of date" (configuration changed), the value is
      unchanged. Asset Valuation -> Recalculation tab: impact shows the
      asset, category move and linked risks; Run with a reason -> value
      moves to the new version; history row RECALC_RUN with the run id;
      the old row is kept.
   5. Run again with the old preview open -> 409 "changed since the
      preview".
   6. Merge or discovery changes a rating -> after the scheduler run the
      asset is recalculated (history SCHEDULER).
   ===================================================================== */
