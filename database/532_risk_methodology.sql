-- =====================================================================
-- 532  Risk methodology -- organisation-configurable, versioned
--
-- REQUEST (2026-11-12)
--   A risk manager asked for velocity beside likelihood and impact. The
--   gap review found nine more commonly used elements missing. Sir:
--   "miss ayi poya 10 fields organization nu configurable aki avarudethaya
--    risk methodology undaki cheyyan patto?" -- then: 3D scoring as an
--   option, methodology versioning, configured by the org admin, build
--   everything except KRIs.
--
-- WHAT AN ORGANISATION CONFIGURES (Settings -> Risk Methodology)
--   * Dimensions -- velocity, proximity, persistence, control
--     effectiveness, confidence, plus any of its own. Per dimension: on /
--     off, required, which stages ask it (inherent / residual / review),
--     its levels, and a priority weight. Convention for every dimension:
--     a HIGHER level means MORE risk (control effectiveness 1 = Effective
--     ... 5 = No controls).
--   * Scoring mode
--       Matrix   -- likelihood x impact through the matrix (as today);
--       Priority -- rating unchanged; priority score =
--                   L x I + SUM(weight x level) over the stage's dimensions;
--       3D       -- score = L x I x (third-axis dimension level), rating
--                   from the version's score bands. Bands use the matrix's
--                   OWN rating codes, so the approval gate, acceptance
--                   authority, register and dashboards keep working.
--   * Appetite (maximum acceptable rating, per category or default),
--     target rating, multi-dimension impact (overall impact = max or
--     average of impact-area levels), trend, quantification (SLE x ARO =
--     ALE, one currency), and a starting template (ISO 31000, COSO ERM,
--     ISO 27005).
--
-- VERSIONING
--   Edits go to a Draft; Publish turns it into the next version and
--   supersedes the previous one. Every assessment row stores the version
--   it was made under, so a risk keeps its values after the methodology
--   changes and is asked the new fields at its next assessment.
--   No published version = today's behaviour, untouched.
--
-- HOW 3D REACHES THE RATING
--   The rating of every assessment (inherent, review re-assessment,
--   residual) is produced by ONE procedure, sp_risk_rating_resolve. It is
--   re-issued here (206 body + the 532 block). The Api puts the page's
--   methodology values in SESSION_CONTEXT('grac.risk.methodology') for the
--   duration of the save, inside one transaction with
--   sp_risk_methodology_assessment_save, so the stored rating and the
--   stored methodology values cannot disagree. rating_score stays on the
--   MATRIX scale (the lowest score of the band's rating), because
--   sp_risk_approval_required compares scores against matrix cells; the
--   raw 3D score is kept in risk_assessment_methodology.score_3d.
--   A save that does not set the context (bulk review, older callers)
--   resolves through the matrix as before.
--
-- IMPACT AREAS belong to the methodology version
--   (risk_methodology_impact_area). 309, which would have added an
--   organisation impact-area master, was WITHDRAWN and never applied, so
--   532 does not depend on it.
--
-- ERRORS 58301-58341 (Api: RiskCentreService, surfaced verbatim).
-- SAFE TO RE-RUN. Requires 204-206, 258, 375, 022, 052. ASCII-only.
-- Rollback: 532_risk_methodology_rollback.sql
-- ALSO EDITED: 274_menu_master_seed.sql (risk-methodology row).
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

-- Guard: every object and column 532 reads. Each missing one is named,
-- so a failed run says exactly what to fix.
DECLARE @missing NVARCHAR(MAX) = N'';
SELECT @missing = @missing + CHAR(13) + CHAR(10) + N'  - ' + x.item
  FROM (VALUES
    (N'procedure grac_practice.sp_risk_rating_resolve (206)',     CASE WHEN OBJECT_ID('grac_practice.sp_risk_rating_resolve','P') IS NULL THEN 1 ELSE 0 END),
    (N'table grac_practice.risk_matrix_cell (204)',               CASE WHEN OBJECT_ID('grac_practice.risk_matrix_cell','U') IS NULL THEN 1 ELSE 0 END),
    (N'table grac_practice.risk_likelihood_master (204)',         CASE WHEN OBJECT_ID('grac_practice.risk_likelihood_master','U') IS NULL THEN 1 ELSE 0 END),
    (N'table grac_practice.risk_impact_master (204)',             CASE WHEN OBJECT_ID('grac_practice.risk_impact_master','U') IS NULL THEN 1 ELSE 0 END),
    (N'table grac_practice.risk_register (205)',                  CASE WHEN OBJECT_ID('grac_practice.risk_register','U') IS NULL THEN 1 ELSE 0 END),
    (N'table grac_practice.risk_analysis (205)',                  CASE WHEN OBJECT_ID('grac_practice.risk_analysis','U') IS NULL THEN 1 ELSE 0 END),
    (N'table grac_practice.risk_residual_analysis (258)',         CASE WHEN OBJECT_ID('grac_practice.risk_residual_analysis','U') IS NULL THEN 1 ELSE 0 END),
    (N'table grac_practice.risk_register_risk_category (375)',    CASE WHEN OBJECT_ID('grac_practice.risk_register_risk_category','U') IS NULL THEN 1 ELSE 0 END),
    (N'table grac_practice.risk_category_master',                 CASE WHEN OBJECT_ID('grac_practice.risk_category_master','U') IS NULL THEN 1 ELSE 0 END),
    (N'column risk_register.residual_analysis_id (258)',          CASE WHEN COL_LENGTH('grac_practice.risk_register','residual_analysis_id') IS NULL THEN 1 ELSE 0 END),
    (N'column risk_register.residual_rating_code (258)',          CASE WHEN COL_LENGTH('grac_practice.risk_register','residual_rating_code') IS NULL THEN 1 ELSE 0 END),
    (N'table grac_practice.menu_master (022)',                    CASE WHEN OBJECT_ID('grac_practice.menu_master','U') IS NULL THEN 1 ELSE 0 END),
    (N'table grac_practice.organization_role_menu_permission (022)', CASE WHEN OBJECT_ID('grac_practice.organization_role_menu_permission','U') IS NULL THEN 1 ELSE 0 END)
  ) x(item, is_missing)
 WHERE x.is_missing = 1;
IF @missing = N'' AND NOT EXISTS (SELECT 1 FROM grac_practice.menu_master WHERE menu_key = N'nav-organization')
    SET @missing = CHAR(13) + CHAR(10) + N'  - menu row nav-organization (052)';
IF @missing <> N''
BEGIN
    PRINT 'ABORT (532): these are missing in this database. Nothing was changed.' + @missing;
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. Configuration tables
-- =====================================================================
IF OBJECT_ID('grac_practice.risk_methodology_version','U') IS NULL
CREATE TABLE grac_practice.risk_methodology_version (
    methodology_version_id  BIGINT IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_risk_methodology_version PRIMARY KEY,
    organization_id         BIGINT NOT NULL
        CONSTRAINT fk_pm_risk_methodology_version_org
        REFERENCES grac_practice.organization(organization_id),
    version_no              INT NULL,                 -- set on publish
    status                  NVARCHAR(20) NOT NULL
        CONSTRAINT df_pm_risk_methodology_version_status DEFAULT (N'Draft'),
    scoring_mode            NVARCHAR(20) NOT NULL
        CONSTRAINT df_pm_risk_methodology_version_mode DEFAULT (N'Matrix'),
    third_axis_code         NVARCHAR(40) NULL,        -- 3D: the dimension multiplied in
    target_rating_enabled   BIT NOT NULL CONSTRAINT df_pm_rmv_target   DEFAULT (0),
    appetite_enabled        BIT NOT NULL CONSTRAINT df_pm_rmv_appetite DEFAULT (0),
    impact_mode             NVARCHAR(20) NOT NULL CONSTRAINT df_pm_rmv_impact DEFAULT (N'Single'),
    trend_enabled           BIT NOT NULL CONSTRAINT df_pm_rmv_trend    DEFAULT (0),
    quantification_enabled  BIT NOT NULL CONSTRAINT df_pm_rmv_quant    DEFAULT (0),
    currency_code           NVARCHAR(10) NULL,
    template_code           NVARCHAR(40) NULL,
    notes                   NVARCHAR(1000) NULL,
    published_dt            DATETIME2 NULL,
    published_by_employee_id BIGINT NULL,
    published_by_name       NVARCHAR(100) NULL,
    entered_by  NVARCHAR(100) NOT NULL CONSTRAINT df_pm_rmv_entered_by DEFAULT (N'system'),
    entered_dt  DATETIME2     NOT NULL CONSTRAINT df_pm_rmv_entered_dt DEFAULT (SYSUTCDATETIME()),
    updated_by  NVARCHAR(100) NULL,
    updated_dt  DATETIME2     NULL,
    CONSTRAINT ck_pm_rmv_status CHECK (status IN (N'Draft', N'Published', N'Superseded')),
    CONSTRAINT ck_pm_rmv_mode   CHECK (scoring_mode IN (N'Matrix', N'Priority', N'3D')),
    CONSTRAINT ck_pm_rmv_impact CHECK (impact_mode IN (N'Single', N'Max', N'Average'))
);
GO
-- The methodology's name (e.g. "ISMS risk methodology 2026"), required on
-- publish. Added separately so a database that ran an earlier 532 gets it.
IF COL_LENGTH('grac_practice.risk_methodology_version','methodology_name') IS NULL
    ALTER TABLE grac_practice.risk_methodology_version ADD methodology_name NVARCHAR(200) NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ux_pm_rmv_one_draft')
    CREATE UNIQUE INDEX ux_pm_rmv_one_draft
        ON grac_practice.risk_methodology_version (organization_id) WHERE status = N'Draft';
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ux_pm_rmv_one_published')
    CREATE UNIQUE INDEX ux_pm_rmv_one_published
        ON grac_practice.risk_methodology_version (organization_id) WHERE status = N'Published';
GO

IF OBJECT_ID('grac_practice.risk_methodology_dimension','U') IS NULL
CREATE TABLE grac_practice.risk_methodology_dimension (
    methodology_dimension_id BIGINT IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_risk_methodology_dimension PRIMARY KEY,
    methodology_version_id   BIGINT NOT NULL
        CONSTRAINT fk_pm_rmd_version REFERENCES grac_practice.risk_methodology_version(methodology_version_id),
    dimension_code   NVARCHAR(40)  NOT NULL,
    dimension_name   NVARCHAR(120) NOT NULL,
    description      NVARCHAR(500) NULL,
    is_enabled       BIT NOT NULL CONSTRAINT df_pm_rmd_enabled  DEFAULT (0),
    is_required      BIT NOT NULL CONSTRAINT df_pm_rmd_required DEFAULT (0),
    ask_inherent     BIT NOT NULL CONSTRAINT df_pm_rmd_inherent DEFAULT (1),
    ask_residual     BIT NOT NULL CONSTRAINT df_pm_rmd_residual DEFAULT (0),
    ask_review       BIT NOT NULL CONSTRAINT df_pm_rmd_review   DEFAULT (1),
    priority_weight  DECIMAL(9,2) NOT NULL CONSTRAINT df_pm_rmd_weight DEFAULT (0),
    display_order    INT NOT NULL CONSTRAINT df_pm_rmd_order DEFAULT (0),
    CONSTRAINT uq_pm_rmd_code UNIQUE (methodology_version_id, dimension_code),
    CONSTRAINT ck_pm_rmd_weight CHECK (priority_weight >= 0)
);
GO

IF OBJECT_ID('grac_practice.risk_methodology_dimension_level','U') IS NULL
CREATE TABLE grac_practice.risk_methodology_dimension_level (
    methodology_level_id   BIGINT IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_risk_methodology_level PRIMARY KEY,
    methodology_version_id BIGINT NOT NULL
        CONSTRAINT fk_pm_rml_version REFERENCES grac_practice.risk_methodology_version(methodology_version_id),
    dimension_code NVARCHAR(40)  NOT NULL,
    level_value    INT           NOT NULL,
    level_name     NVARCHAR(120) NOT NULL,
    descriptor     NVARCHAR(500) NULL,
    colour_hex     NVARCHAR(10)  NULL,
    CONSTRAINT uq_pm_rml_level UNIQUE (methodology_version_id, dimension_code, level_value),
    CONSTRAINT ck_pm_rml_level CHECK (level_value BETWEEN 1 AND 10)
);
GO

IF OBJECT_ID('grac_practice.risk_methodology_score_band','U') IS NULL
CREATE TABLE grac_practice.risk_methodology_score_band (
    methodology_band_id    BIGINT IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_risk_methodology_band PRIMARY KEY,
    methodology_version_id BIGINT NOT NULL
        CONSTRAINT fk_pm_rmb_version REFERENCES grac_practice.risk_methodology_version(methodology_version_id),
    min_score   INT NOT NULL,
    max_score   INT NOT NULL,
    rating_code NVARCHAR(30) NOT NULL,           -- one of the matrix's rating codes
    CONSTRAINT ck_pm_rmb_range CHECK (min_score >= 1 AND max_score >= min_score)
);
GO

IF OBJECT_ID('grac_practice.risk_methodology_appetite','U') IS NULL
CREATE TABLE grac_practice.risk_methodology_appetite (
    methodology_appetite_id BIGINT IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_risk_methodology_appetite PRIMARY KEY,
    methodology_version_id  BIGINT NOT NULL
        CONSTRAINT fk_pm_rma_version REFERENCES grac_practice.risk_methodology_version(methodology_version_id),
    risk_category_code NVARCHAR(60)   NULL,      -- NULL = default for every category
    max_rating_code    NVARCHAR(30)   NOT NULL,  -- highest acceptable rating
    appetite_statement NVARCHAR(1000) NULL
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ux_pm_rma_category')
    CREATE UNIQUE INDEX ux_pm_rma_category
        ON grac_practice.risk_methodology_appetite (methodology_version_id, risk_category_code)
        WHERE risk_category_code IS NOT NULL;
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ux_pm_rma_default')
    CREATE UNIQUE INDEX ux_pm_rma_default
        ON grac_practice.risk_methodology_appetite (methodology_version_id)
        WHERE risk_category_code IS NULL;
GO

-- Impact areas rated separately when impact_mode is Max / Average.
IF OBJECT_ID('grac_practice.risk_methodology_impact_area','U') IS NULL
CREATE TABLE grac_practice.risk_methodology_impact_area (
    methodology_area_id    BIGINT IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_risk_methodology_area PRIMARY KEY,
    methodology_version_id BIGINT NOT NULL
        CONSTRAINT fk_pm_rmia_version REFERENCES grac_practice.risk_methodology_version(methodology_version_id),
    area_code     NVARCHAR(60)  NOT NULL,
    area_name     NVARCHAR(200) NOT NULL,
    display_order INT NOT NULL CONSTRAINT df_pm_rmia_order DEFAULT (0),
    CONSTRAINT uq_pm_rmia_code UNIQUE (methodology_version_id, area_code)
);
GO

-- =====================================================================
-- 2. Assessment tables -- one row per scored assessment, stamped with
--    the version it was made under.
-- =====================================================================
IF OBJECT_ID('grac_practice.risk_assessment_methodology','U') IS NULL
CREATE TABLE grac_practice.risk_assessment_methodology (
    assessment_methodology_id BIGINT IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_risk_assessment_methodology PRIMARY KEY,
    organization_id          BIGINT NOT NULL,
    risk_register_id         BIGINT NOT NULL
        CONSTRAINT fk_pm_ram_register REFERENCES grac_practice.risk_register(risk_register_id),
    stage_code               NVARCHAR(20) NOT NULL,   -- Inherent | Residual
    source_code              NVARCHAR(20) NOT NULL,   -- Assess | Review | Residual
    risk_analysis_id         BIGINT NULL
        CONSTRAINT fk_pm_ram_analysis REFERENCES grac_practice.risk_analysis(risk_analysis_id),
    risk_residual_analysis_id BIGINT NULL
        CONSTRAINT fk_pm_ram_residual REFERENCES grac_practice.risk_residual_analysis(risk_residual_analysis_id),
    methodology_version_id   BIGINT NOT NULL
        CONSTRAINT fk_pm_ram_version REFERENCES grac_practice.risk_methodology_version(methodology_version_id),
    scoring_mode             NVARCHAR(20) NOT NULL,
    likelihood_value         INT NULL,
    impact_value             INT NULL,
    matrix_rating_code       NVARCHAR(30) NULL,       -- what L x I alone gives
    effective_rating_code    NVARCHAR(30) NULL,       -- what was stored on the assessment
    score_3d                 INT NULL,
    priority_score           DECIMAL(12,2) NULL,
    target_rating_code       NVARCHAR(30) NULL,
    impact_mode              NVARCHAR(20) NOT NULL,
    derived_impact_value     INT NULL,
    single_loss_amount       DECIMAL(19,2) NULL,
    annual_rate              DECIMAL(9,4)  NULL,
    annual_loss_amount       DECIMAL(19,2) NULL,
    currency_code            NVARCHAR(10)  NULL,
    actor_employee_id        BIGINT NULL,
    entered_by NVARCHAR(100) NOT NULL CONSTRAINT df_pm_ram_entered_by DEFAULT (N'system'),
    entered_dt DATETIME2     NOT NULL CONSTRAINT df_pm_ram_entered_dt DEFAULT (SYSUTCDATETIME()),
    CONSTRAINT ck_pm_ram_stage  CHECK (stage_code  IN (N'Inherent', N'Residual')),
    CONSTRAINT ck_pm_ram_source CHECK (source_code IN (N'Assess', N'Review', N'Residual'))
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ix_pm_ram_register')
    CREATE INDEX ix_pm_ram_register
        ON grac_practice.risk_assessment_methodology (risk_register_id, stage_code)
        INCLUDE (risk_analysis_id, risk_residual_analysis_id);
GO

IF OBJECT_ID('grac_practice.risk_assessment_dimension_value','U') IS NULL
CREATE TABLE grac_practice.risk_assessment_dimension_value (
    assessment_value_id       BIGINT IDENTITY(1,1) NOT NULL
        CONSTRAINT pk_pm_risk_assessment_dimension_value PRIMARY KEY,
    assessment_methodology_id BIGINT NOT NULL
        CONSTRAINT fk_pm_radv_assessment REFERENCES grac_practice.risk_assessment_methodology(assessment_methodology_id),
    value_kind     NVARCHAR(20)  NOT NULL,    -- Dimension | ImpactArea
    value_code     NVARCHAR(60)  NOT NULL,    -- dimension_code or impact area_code
    value_label    NVARCHAR(200) NULL,        -- dimension / area name, frozen
    level_value    INT           NOT NULL,
    level_name     NVARCHAR(200) NULL,        -- frozen
    CONSTRAINT ck_pm_radv_kind CHECK (value_kind IN (N'Dimension', N'ImpactArea'))
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ix_pm_radv_assessment')
    CREATE INDEX ix_pm_radv_assessment
        ON grac_practice.risk_assessment_dimension_value (assessment_methodology_id);
GO

-- =====================================================================
-- 3. fn_risk_rating_rank -- the order of an organisation's ratings.
--    The LOWEST score of a rating's matrix cells, which is exactly the
--    threshold sp_risk_approval_required compares against; L x I where a
--    cell has no score.
-- =====================================================================
CREATE OR ALTER FUNCTION grac_practice.fn_risk_rating_rank
(
    @organization_id BIGINT,
    @rating_code     NVARCHAR(30)
)
RETURNS INT
AS
BEGIN
    RETURN (SELECT MIN(ISNULL(rating_score, likelihood_value * impact_value))
              FROM grac_practice.risk_matrix_cell
             WHERE organization_id = @organization_id
               AND rating_code     = @rating_code);
END;
GO

-- =====================================================================
-- 4. sp_risk_rating_resolve (206 body, verbatim, + the 532 block)
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_rating_resolve
    @organization_id  BIGINT,
    @likelihood_value INT,
    @impact_value     INT,
    @rating_code      NVARCHAR(30)  OUTPUT,
    @rating_name      NVARCHAR(120) OUTPUT,
    @rating_score     INT           OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    SET @rating_code  = NULL;
    SET @rating_name  = NULL;
    SET @rating_score = NULL;

    IF @organization_id IS NULL
        THROW 56041, 'sp_risk_rating_resolve: organization_id is required.', 1;

    -- A partially scored analysis is legal while the analyst is still
    -- working (BRD 7 lists the fields, BRD 8 is where completeness is judged),
    -- so an unscored pair resolves to NULL rather than throwing.
    IF @likelihood_value IS NULL OR @impact_value IS NULL
        RETURN;

    SELECT @rating_code  = rating_code,
           @rating_name  = rating_name,
           @rating_score = rating_score
      FROM grac_practice.risk_matrix_cell
     WHERE organization_id  = @organization_id
       AND likelihood_value = @likelihood_value
       AND impact_value     = @impact_value;

    -- A scored pair with no matrix cell is a configuration error, not a
    -- data error: the organisation offered a level its matrix does not
    -- cover. Fail loudly -- silently registering an unrated risk would
    -- breach BRD 9.1.
    IF @rating_code IS NULL
        THROW 56042, 'sp_risk_rating_resolve: no matrix cell for this likelihood/impact pair. Check the organisation''s risk matrix configuration.', 1;

    -- ---- 532: 3D scoring -------------------------------------------
    -- Only when the organisation's PUBLISHED methodology is 3D AND the
    -- caller (the Api, inside the save's transaction) has put the page's
    -- methodology values in SESSION_CONTEXT. Otherwise the matrix answer
    -- above stands, exactly as before 532.
    DECLARE @ctx NVARCHAR(MAX) = CAST(SESSION_CONTEXT(N'grac.risk.methodology') AS NVARCHAR(MAX));
    IF @ctx IS NULL OR ISJSON(@ctx) = 0 RETURN;

    DECLARE @mv_id BIGINT, @third NVARCHAR(40), @third_name NVARCHAR(120);
    SELECT @mv_id = v.methodology_version_id, @third = v.third_axis_code
      FROM grac_practice.risk_methodology_version v
     WHERE v.organization_id = @organization_id
       AND v.status          = N'Published'
       AND v.scoring_mode    = N'3D';
    IF @mv_id IS NULL RETURN;

    SELECT @third_name = dimension_name
      FROM grac_practice.risk_methodology_dimension
     WHERE methodology_version_id = @mv_id AND dimension_code = @third;

    DECLARE @third_level INT =
        (SELECT TOP (1) TRY_CONVERT(INT, j.levelValue)
           FROM OPENJSON(@ctx, '$.values')
                WITH (dimensionCode NVARCHAR(40) '$.dimensionCode',
                      levelValue    NVARCHAR(20) '$.levelValue') j
          WHERE j.dimensionCode = @third);

    IF @third_level IS NULL
    BEGIN
        DECLARE @m58301 NVARCHAR(400) = CONCAT(N'3D scoring needs ', ISNULL(@third_name, @third), N'. Select it before saving.');
        THROW 58301, @m58301, 1;
    END
    IF NOT EXISTS (SELECT 1 FROM grac_practice.risk_methodology_dimension_level
                    WHERE methodology_version_id = @mv_id AND dimension_code = @third AND level_value = @third_level)
        THROW 58302, 'Unknown level for the 3D scoring dimension.', 1;

    DECLARE @score_3d INT = @likelihood_value * @impact_value * @third_level;
    DECLARE @band_code NVARCHAR(30) =
        (SELECT TOP (1) rating_code FROM grac_practice.risk_methodology_score_band
          WHERE methodology_version_id = @mv_id
            AND @score_3d BETWEEN min_score AND max_score
          ORDER BY min_score);
    IF @band_code IS NULL
    BEGIN
        DECLARE @m58303 NVARCHAR(400) = CONCAT(N'No 3D score band covers score ', @score_3d,
                                               N'. Check Settings -> Risk Methodology.');
        THROW 58303, @m58303, 1;
    END

    SELECT TOP (1) @rating_code = rating_code, @rating_name = rating_name
      FROM grac_practice.risk_matrix_cell
     WHERE organization_id = @organization_id AND rating_code = @band_code;
    -- Matrix scale on purpose: sp_risk_approval_required compares this
    -- score with matrix cells. The raw 3D score is kept by
    -- sp_risk_methodology_assessment_save.
    SET @rating_score = grac_practice.fn_risk_rating_rank(@organization_id, @band_code);
END;
GO

-- =====================================================================
-- 5. Templates -- fills a draft. Every standard dimension is written
--    (so the org can switch any on later); the template switches on its
--    own set. Levels follow "higher = more risk".
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_methodology_template_fill
    @methodology_version_id BIGINT,
    @template_code          NVARCHAR(40)
AS
BEGIN
    SET NOCOUNT ON;
    IF @template_code NOT IN (N'BLANK', N'ISO31000', N'COSO_ERM', N'ISO27005')
        THROW 58304, 'Unknown methodology template.', 1;

    DELETE FROM grac_practice.risk_methodology_dimension_level WHERE methodology_version_id = @methodology_version_id;
    DELETE FROM grac_practice.risk_methodology_dimension       WHERE methodology_version_id = @methodology_version_id;
    DELETE FROM grac_practice.risk_methodology_score_band      WHERE methodology_version_id = @methodology_version_id;
    DELETE FROM grac_practice.risk_methodology_appetite        WHERE methodology_version_id = @methodology_version_id;
    DELETE FROM grac_practice.risk_methodology_impact_area     WHERE methodology_version_id = @methodology_version_id;

    INSERT grac_practice.risk_methodology_dimension
        (methodology_version_id, dimension_code, dimension_name, description,
         is_enabled, is_required, ask_inherent, ask_residual, ask_review, priority_weight, display_order)
    SELECT @methodology_version_id, d.code, d.name, d.descr,
           CASE WHEN (@template_code = N'ISO31000' AND d.code IN (N'PROXIMITY', N'CONFIDENCE'))
                  OR (@template_code = N'COSO_ERM' AND d.code IN (N'VELOCITY', N'PERSISTENCE', N'PROXIMITY'))
                  OR (@template_code = N'ISO27005' AND d.code IN (N'CONTROL_EFFECTIVENESS', N'CONFIDENCE'))
                THEN 1 ELSE 0 END,
           CASE WHEN (@template_code = N'COSO_ERM' AND d.code = N'VELOCITY')
                  OR (@template_code = N'ISO27005' AND d.code = N'CONTROL_EFFECTIVENESS')
                THEN 1 ELSE 0 END,
           d.ask_i, d.ask_r, d.ask_v,
           CASE WHEN @template_code = N'COSO_ERM' AND d.code IN (N'VELOCITY', N'PERSISTENCE') THEN 1 ELSE 0 END,
           d.ord
      FROM (VALUES
        (N'VELOCITY',              N'Velocity',              N'How fast the impact is felt once the risk materialises.',            1, 1, 1, 10),
        (N'PROXIMITY',             N'Proximity',             N'How soon the risk could materialise.',                              1, 0, 1, 20),
        (N'PERSISTENCE',           N'Persistence',           N'How long the impact lasts once the risk materialises.',             1, 1, 1, 30),
        (N'CONTROL_EFFECTIVENESS', N'Control effectiveness', N'How well the existing controls work (higher = weaker controls).',   0, 1, 1, 40),
        (N'CONFIDENCE',            N'Assessment confidence', N'How sure the assessor is of this score (higher = less confident).', 1, 1, 1, 50)
      ) d(code, name, descr, ask_i, ask_r, ask_v, ord);

    INSERT grac_practice.risk_methodology_dimension_level
        (methodology_version_id, dimension_code, level_value, level_name, descriptor)
    SELECT @methodology_version_id, l.code, l.lv, l.name, l.descr
      FROM (VALUES
        (N'VELOCITY', 1, N'Slow',      N'Impact felt over more than a year'),
        (N'VELOCITY', 2, N'Moderate',  N'Impact felt over months'),
        (N'VELOCITY', 3, N'Fast',      N'Impact felt within weeks'),
        (N'VELOCITY', 4, N'Very fast', N'Impact felt within days or hours'),
        (N'PROXIMITY', 1, N'Long term',   N'More than 3 years away'),
        (N'PROXIMITY', 2, N'Medium term', N'Within 1 to 3 years'),
        (N'PROXIMITY', 3, N'Short term',  N'Within 12 months'),
        (N'PROXIMITY', 4, N'Immediate',   N'Within 3 months'),
        (N'PERSISTENCE', 1, N'Brief',        N'Impact lasts days'),
        (N'PERSISTENCE', 2, N'Short',        N'Impact lasts weeks'),
        (N'PERSISTENCE', 3, N'Prolonged',    N'Impact lasts months'),
        (N'PERSISTENCE', 4, N'Long lasting', N'Impact lasts a year or more'),
        (N'CONTROL_EFFECTIVENESS', 1, N'Effective',           N'Controls designed and operating well'),
        (N'CONTROL_EFFECTIVENESS', 2, N'Largely effective',   N'Minor weaknesses'),
        (N'CONTROL_EFFECTIVENESS', 3, N'Partially effective', N'Significant weaknesses'),
        (N'CONTROL_EFFECTIVENESS', 4, N'Ineffective',         N'Controls exist but do not work'),
        (N'CONTROL_EFFECTIVENESS', 5, N'No controls',         N'No control in place'),
        (N'CONFIDENCE', 1, N'High',   N'Strong evidence and data'),
        (N'CONFIDENCE', 2, N'Medium', N'Some evidence, some judgement'),
        (N'CONFIDENCE', 3, N'Low',    N'Mostly judgement, little information')
      ) l(code, lv, name, descr);

    -- The impact areas 309 would have seeded, now owned by the version.
    INSERT grac_practice.risk_methodology_impact_area (methodology_version_id, area_code, area_name, display_order)
    SELECT @methodology_version_id, a.code, a.name, a.ord
      FROM (VALUES
        (N'Financial',     N'Financial',            10),
        (N'Operational',   N'Operational',          20),
        (N'Legal',         N'Legal & Regulatory',   30),
        (N'Reputational',  N'Reputational',         40),
        (N'Customer',      N'Customer',             50),
        (N'People',        N'People',               60),
        (N'InfoSec',       N'Information Security', 70),
        (N'Environmental', N'Environmental',        80)
      ) a(code, name, ord);

    UPDATE grac_practice.risk_methodology_version
       SET template_code          = @template_code,
           methodology_name       = ISNULL(methodology_name,
                                      CASE @template_code WHEN N'ISO31000' THEN N'ISO 31000 based risk methodology'
                                                          WHEN N'COSO_ERM' THEN N'COSO ERM based risk methodology'
                                                          WHEN N'ISO27005' THEN N'ISO 27005 based risk methodology'
                                                          ELSE NULL END),
           scoring_mode           = CASE WHEN @template_code = N'COSO_ERM' THEN N'Priority' ELSE N'Matrix' END,
           third_axis_code        = N'VELOCITY',
           target_rating_enabled  = CASE WHEN @template_code IN (N'ISO31000', N'COSO_ERM') THEN 1 ELSE 0 END,
           appetite_enabled       = CASE WHEN @template_code IN (N'ISO31000', N'COSO_ERM') THEN 1 ELSE 0 END,
           impact_mode            = CASE WHEN @template_code = N'ISO27005' THEN N'Max' ELSE N'Single' END,
           trend_enabled          = CASE WHEN @template_code = N'BLANK' THEN 0 ELSE 1 END,
           quantification_enabled = CASE WHEN @template_code = N'ISO27005' THEN 1 ELSE 0 END
     WHERE methodology_version_id = @methodology_version_id;
END;
GO

-- =====================================================================
-- 6. sp_risk_methodology_get -- published + draft, everything the
--    settings screen and the risk pages need.
--    Result sets: 1 versions, 2 dimensions, 3 levels, 4 bands,
--    5 appetite, 6 rating options (matrix), 7 impact areas,
--    8 categories, 9 published history, 10 scale limits.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_methodology_get
    @organization_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL
        THROW 58305, 'sp_risk_methodology_get: organization_id is required.', 1;

    SELECT v.methodology_version_id AS MethodologyVersionId, v.version_no AS VersionNo,
           v.status AS Status, v.scoring_mode AS ScoringMode, v.third_axis_code AS ThirdAxisCode,
           v.target_rating_enabled AS TargetRatingEnabled, v.appetite_enabled AS AppetiteEnabled,
           v.impact_mode AS ImpactMode, v.trend_enabled AS TrendEnabled,
           v.quantification_enabled AS QuantificationEnabled, v.currency_code AS CurrencyCode,
           v.template_code AS TemplateCode, v.notes AS Notes, v.methodology_name AS MethodologyName,
           v.published_dt AS PublishedDt, v.published_by_name AS PublishedByName,
           v.updated_dt AS UpdatedDt, v.updated_by AS UpdatedBy
      FROM grac_practice.risk_methodology_version v
     WHERE v.organization_id = @organization_id AND v.status IN (N'Published', N'Draft');

    SELECT d.methodology_version_id AS MethodologyVersionId, d.dimension_code AS DimensionCode,
           d.dimension_name AS DimensionName, d.description AS Description,
           d.is_enabled AS IsEnabled, d.is_required AS IsRequired,
           d.ask_inherent AS AskInherent, d.ask_residual AS AskResidual, d.ask_review AS AskReview,
           d.priority_weight AS PriorityWeight, d.display_order AS DisplayOrder
      FROM grac_practice.risk_methodology_dimension d
      JOIN grac_practice.risk_methodology_version v ON v.methodology_version_id = d.methodology_version_id
     WHERE v.organization_id = @organization_id AND v.status IN (N'Published', N'Draft')
     ORDER BY d.methodology_version_id, d.display_order, d.dimension_code;

    SELECT l.methodology_version_id AS MethodologyVersionId, l.dimension_code AS DimensionCode,
           l.level_value AS LevelValue, l.level_name AS LevelName,
           l.descriptor AS Descriptor, l.colour_hex AS ColourHex
      FROM grac_practice.risk_methodology_dimension_level l
      JOIN grac_practice.risk_methodology_version v ON v.methodology_version_id = l.methodology_version_id
     WHERE v.organization_id = @organization_id AND v.status IN (N'Published', N'Draft')
     ORDER BY l.methodology_version_id, l.dimension_code, l.level_value;

    SELECT b.methodology_version_id AS MethodologyVersionId, b.min_score AS MinScore,
           b.max_score AS MaxScore, b.rating_code AS RatingCode
      FROM grac_practice.risk_methodology_score_band b
      JOIN grac_practice.risk_methodology_version v ON v.methodology_version_id = b.methodology_version_id
     WHERE v.organization_id = @organization_id AND v.status IN (N'Published', N'Draft')
     ORDER BY b.methodology_version_id, b.min_score;

    SELECT a.methodology_version_id AS MethodologyVersionId, a.risk_category_code AS RiskCategoryCode,
           a.max_rating_code AS MaxRatingCode, a.appetite_statement AS AppetiteStatement
      FROM grac_practice.risk_methodology_appetite a
      JOIN grac_practice.risk_methodology_version v ON v.methodology_version_id = a.methodology_version_id
     WHERE v.organization_id = @organization_id AND v.status IN (N'Published', N'Draft')
     ORDER BY a.methodology_version_id, a.risk_category_code;

    SELECT c.rating_code AS RatingCode, MIN(c.rating_name) AS RatingName,
           MIN(c.colour_hex) AS ColourHex,
           MIN(ISNULL(c.rating_score, c.likelihood_value * c.impact_value)) AS RatingRank
      FROM grac_practice.risk_matrix_cell c
     WHERE c.organization_id = @organization_id
     GROUP BY c.rating_code
     ORDER BY RatingRank;

    SELECT a.methodology_version_id AS MethodologyVersionId, a.area_code AS AreaCode,
           a.area_name AS AreaName, a.display_order AS DisplayOrder
      FROM grac_practice.risk_methodology_impact_area a
      JOIN grac_practice.risk_methodology_version v ON v.methodology_version_id = a.methodology_version_id
     WHERE v.organization_id = @organization_id AND v.status IN (N'Published', N'Draft')
     ORDER BY a.methodology_version_id, a.display_order, a.area_name;

    SELECT c.category_code AS CategoryCode, c.category_name AS CategoryName
      FROM grac_practice.risk_category_master c
     WHERE c.organization_id = @organization_id AND c.status = N'Active'
     ORDER BY c.display_order, c.category_name;

    SELECT v.methodology_version_id AS MethodologyVersionId, v.version_no AS VersionNo,
           v.status AS Status, v.scoring_mode AS ScoringMode, v.template_code AS TemplateCode,
           v.methodology_name AS MethodologyName,
           v.published_dt AS PublishedDt, v.published_by_name AS PublishedByName
      FROM grac_practice.risk_methodology_version v
     WHERE v.organization_id = @organization_id AND v.status IN (N'Published', N'Superseded')
     ORDER BY v.version_no DESC;

    SELECT (SELECT MAX(level_value) FROM grac_practice.risk_likelihood_master
             WHERE organization_id = @organization_id AND status = N'Active') AS MaxLikelihood,
           (SELECT MAX(level_value) FROM grac_practice.risk_impact_master
             WHERE organization_id = @organization_id AND status = N'Active') AS MaxImpact;
END;
GO

-- =====================================================================
-- 7. Draft lifecycle
-- =====================================================================
-- Starts a draft: a copy of the published version, or a template.
-- @replace = 1 throws an existing draft away first.
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_methodology_draft_create
    @organization_id     BIGINT,
    @template_code       NVARCHAR(40)  = NULL,   -- NULL = copy the published version
    @replace             BIT           = 0,
    @caller_display_name NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 58306, 'Organization not found.', 1;

    DECLARE @draft_id BIGINT = (SELECT methodology_version_id FROM grac_practice.risk_methodology_version
                                 WHERE organization_id = @organization_id AND status = N'Draft');
    IF @draft_id IS NOT NULL AND ISNULL(@replace, 0) = 0
        THROW 58307, 'A draft already exists. Edit it, or discard it first.', 1;

    DECLARE @pub_id BIGINT = (SELECT methodology_version_id FROM grac_practice.risk_methodology_version
                               WHERE organization_id = @organization_id AND status = N'Published');
    IF @template_code IS NULL AND @pub_id IS NULL
        SET @template_code = N'BLANK';

    BEGIN TRAN;
        IF @draft_id IS NOT NULL
        BEGIN
            DELETE FROM grac_practice.risk_methodology_dimension_level WHERE methodology_version_id = @draft_id;
            DELETE FROM grac_practice.risk_methodology_dimension       WHERE methodology_version_id = @draft_id;
            DELETE FROM grac_practice.risk_methodology_score_band      WHERE methodology_version_id = @draft_id;
            DELETE FROM grac_practice.risk_methodology_appetite        WHERE methodology_version_id = @draft_id;
            DELETE FROM grac_practice.risk_methodology_impact_area     WHERE methodology_version_id = @draft_id;
            DELETE FROM grac_practice.risk_methodology_version         WHERE methodology_version_id = @draft_id;
        END

        INSERT grac_practice.risk_methodology_version
            (organization_id, status, scoring_mode, third_axis_code, target_rating_enabled, appetite_enabled,
             impact_mode, trend_enabled, quantification_enabled, currency_code, template_code, notes,
             methodology_name, entered_by)
        SELECT @organization_id, N'Draft',
               ISNULL(p.scoring_mode, N'Matrix'), p.third_axis_code,
               ISNULL(p.target_rating_enabled, 0), ISNULL(p.appetite_enabled, 0),
               ISNULL(p.impact_mode, N'Single'), ISNULL(p.trend_enabled, 0),
               ISNULL(p.quantification_enabled, 0), p.currency_code, p.template_code, p.notes,
               p.methodology_name,
               @caller_display_name
          FROM (SELECT 1 AS one) x
          LEFT JOIN grac_practice.risk_methodology_version p
                 ON p.methodology_version_id = @pub_id AND @template_code IS NULL;
        SET @draft_id = SCOPE_IDENTITY();

        IF @template_code IS NOT NULL
            EXEC grac_practice.sp_risk_methodology_template_fill @draft_id, @template_code;
        ELSE
        BEGIN
            INSERT grac_practice.risk_methodology_dimension
                (methodology_version_id, dimension_code, dimension_name, description, is_enabled, is_required,
                 ask_inherent, ask_residual, ask_review, priority_weight, display_order)
            SELECT @draft_id, dimension_code, dimension_name, description, is_enabled, is_required,
                   ask_inherent, ask_residual, ask_review, priority_weight, display_order
              FROM grac_practice.risk_methodology_dimension WHERE methodology_version_id = @pub_id;
            INSERT grac_practice.risk_methodology_dimension_level
                (methodology_version_id, dimension_code, level_value, level_name, descriptor, colour_hex)
            SELECT @draft_id, dimension_code, level_value, level_name, descriptor, colour_hex
              FROM grac_practice.risk_methodology_dimension_level WHERE methodology_version_id = @pub_id;
            INSERT grac_practice.risk_methodology_score_band (methodology_version_id, min_score, max_score, rating_code)
            SELECT @draft_id, min_score, max_score, rating_code
              FROM grac_practice.risk_methodology_score_band WHERE methodology_version_id = @pub_id;
            INSERT grac_practice.risk_methodology_appetite (methodology_version_id, risk_category_code, max_rating_code, appetite_statement)
            SELECT @draft_id, risk_category_code, max_rating_code, appetite_statement
              FROM grac_practice.risk_methodology_appetite WHERE methodology_version_id = @pub_id;
            INSERT grac_practice.risk_methodology_impact_area (methodology_version_id, area_code, area_name, display_order)
            SELECT @draft_id, area_code, area_name, display_order
              FROM grac_practice.risk_methodology_impact_area WHERE methodology_version_id = @pub_id;
        END
    COMMIT;

    SELECT @draft_id AS MethodologyVersionId;
END;
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_risk_methodology_draft_discard
    @organization_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @draft_id BIGINT = (SELECT methodology_version_id FROM grac_practice.risk_methodology_version
                                 WHERE organization_id = @organization_id AND status = N'Draft');
    IF @draft_id IS NULL
        THROW 58308, 'There is no draft to discard.', 1;
    BEGIN TRAN;
        DELETE FROM grac_practice.risk_methodology_dimension_level WHERE methodology_version_id = @draft_id;
        DELETE FROM grac_practice.risk_methodology_dimension       WHERE methodology_version_id = @draft_id;
        DELETE FROM grac_practice.risk_methodology_score_band      WHERE methodology_version_id = @draft_id;
        DELETE FROM grac_practice.risk_methodology_appetite        WHERE methodology_version_id = @draft_id;
        DELETE FROM grac_practice.risk_methodology_impact_area     WHERE methodology_version_id = @draft_id;
        DELETE FROM grac_practice.risk_methodology_version         WHERE methodology_version_id = @draft_id;
    COMMIT;
    SELECT CAST(1 AS BIT) AS Discarded;
END;
GO

-- Replaces the draft's header and children with the payload:
--  { scoringMode, thirdAxisCode, targetRatingEnabled, appetiteEnabled,
--    impactMode, trendEnabled, quantificationEnabled, currencyCode, notes,
--    dimensions: [{ dimensionCode, dimensionName, description, isEnabled,
--      isRequired, askInherent, askResidual, askReview, priorityWeight,
--      displayOrder, levels: [{ levelValue, levelName, descriptor, colourHex }] }],
--    bands: [{ minScore, maxScore, ratingCode }],
--    appetite: [{ riskCategoryCode, maxRatingCode, appetiteStatement }] }
-- Shape checks only; completeness is checked on publish.
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_methodology_draft_save
    @organization_id     BIGINT,
    @payload             NVARCHAR(MAX),
    @caller_display_name NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF @payload IS NULL OR ISJSON(@payload) = 0
        THROW 58309, 'The methodology payload is not valid JSON.', 1;
    DECLARE @draft_id BIGINT = (SELECT methodology_version_id FROM grac_practice.risk_methodology_version
                                 WHERE organization_id = @organization_id AND status = N'Draft');
    IF @draft_id IS NULL
        THROW 58310, 'Start a draft before saving changes.', 1;

    DECLARE @mode NVARCHAR(20) = ISNULL(JSON_VALUE(@payload, '$.scoringMode'), N'Matrix');
    DECLARE @impact NVARCHAR(20) = ISNULL(JSON_VALUE(@payload, '$.impactMode'), N'Single');
    IF @mode NOT IN (N'Matrix', N'Priority', N'3D')
        THROW 58311, 'Scoring mode must be Matrix, Priority or 3D.', 1;
    IF @impact NOT IN (N'Single', N'Max', N'Average')
        THROW 58312, 'Impact mode must be Single, Max or Average.', 1;

    -- Dimensions and levels, staged first so duplicate codes fail cleanly.
    DECLARE @dims TABLE (code NVARCHAR(40), name NVARCHAR(120), descr NVARCHAR(500), en BIT, req BIT,
                         ai BIT, ar BIT, av BIT, w DECIMAL(9,2), ord INT, levels NVARCHAR(MAX));
    INSERT @dims
    SELECT UPPER(LTRIM(RTRIM(d.code))), LTRIM(RTRIM(d.name)), d.descr,
           ISNULL(d.en, 0), ISNULL(d.req, 0), ISNULL(d.ai, 0), ISNULL(d.ar, 0), ISNULL(d.av, 0),
           ISNULL(d.w, 0), ISNULL(d.ord, 0), d.levels
      FROM OPENJSON(@payload, '$.dimensions')
           WITH (code NVARCHAR(40) '$.dimensionCode', name NVARCHAR(120) '$.dimensionName',
                 descr NVARCHAR(500) '$.description', en BIT '$.isEnabled', req BIT '$.isRequired',
                 ai BIT '$.askInherent', ar BIT '$.askResidual', av BIT '$.askReview',
                 w DECIMAL(9,2) '$.priorityWeight', ord INT '$.displayOrder',
                 levels NVARCHAR(MAX) '$.levels' AS JSON) d;
    IF EXISTS (SELECT 1 FROM @dims WHERE code IS NULL OR code = N'' OR name IS NULL OR name = N''
                                      OR code LIKE N'%[^A-Z0-9_]%')
        THROW 58313, 'Every dimension needs a code (A-Z, 0-9, _) and a name.', 1;
    IF EXISTS (SELECT code FROM @dims GROUP BY code HAVING COUNT(*) > 1)
        THROW 58314, 'Two dimensions have the same code.', 1;
    IF EXISTS (SELECT 1 FROM @dims WHERE w < 0)
        THROW 58315, 'A priority weight cannot be negative.', 1;

    DECLARE @levels TABLE (code NVARCHAR(40), lv INT, name NVARCHAR(120), descr NVARCHAR(500), colour NVARCHAR(10));
    INSERT @levels
    SELECT d.code, l.lv, LTRIM(RTRIM(l.name)), l.descr, l.colour
      FROM @dims d
     CROSS APPLY OPENJSON(d.levels)
           WITH (lv INT '$.levelValue', name NVARCHAR(120) '$.levelName',
                 descr NVARCHAR(500) '$.descriptor', colour NVARCHAR(10) '$.colourHex') l;
    IF EXISTS (SELECT 1 FROM @levels WHERE lv IS NULL OR lv NOT BETWEEN 1 AND 10 OR name IS NULL OR name = N'')
        THROW 58316, 'Every level needs a value from 1 to 10 and a name.', 1;
    IF EXISTS (SELECT code, lv FROM @levels GROUP BY code, lv HAVING COUNT(*) > 1)
        THROW 58317, 'A dimension has two levels with the same value.', 1;
    IF EXISTS (SELECT UPPER(LTRIM(RTRIM(code))) FROM OPENJSON(@payload, '$.impactAreas')
                      WITH (code NVARCHAR(60) '$.areaCode')
                WHERE LEN(LTRIM(RTRIM(ISNULL(code, N'')))) > 0
                GROUP BY UPPER(LTRIM(RTRIM(code))) HAVING COUNT(*) > 1)
        THROW 58340, 'Two impact areas have the same code.', 1;

    BEGIN TRAN;
        UPDATE grac_practice.risk_methodology_version
           SET scoring_mode           = @mode,
               third_axis_code        = NULLIF(UPPER(LTRIM(RTRIM(JSON_VALUE(@payload, '$.thirdAxisCode')))), N''),
               target_rating_enabled  = ISNULL(TRY_CONVERT(BIT, JSON_VALUE(@payload, '$.targetRatingEnabled')), 0),
               appetite_enabled       = ISNULL(TRY_CONVERT(BIT, JSON_VALUE(@payload, '$.appetiteEnabled')), 0),
               impact_mode            = @impact,
               trend_enabled          = ISNULL(TRY_CONVERT(BIT, JSON_VALUE(@payload, '$.trendEnabled')), 0),
               quantification_enabled = ISNULL(TRY_CONVERT(BIT, JSON_VALUE(@payload, '$.quantificationEnabled')), 0),
               currency_code          = NULLIF(UPPER(LTRIM(RTRIM(JSON_VALUE(@payload, '$.currencyCode')))), N''),
               notes                  = JSON_VALUE(@payload, '$.notes'),
               methodology_name       = NULLIF(LTRIM(RTRIM(JSON_VALUE(@payload, '$.methodologyName'))), N''),
               updated_by             = @caller_display_name,
               updated_dt             = SYSUTCDATETIME()
         WHERE methodology_version_id = @draft_id;

        DELETE FROM grac_practice.risk_methodology_dimension_level WHERE methodology_version_id = @draft_id;
        DELETE FROM grac_practice.risk_methodology_dimension       WHERE methodology_version_id = @draft_id;
        DELETE FROM grac_practice.risk_methodology_score_band      WHERE methodology_version_id = @draft_id;
        DELETE FROM grac_practice.risk_methodology_appetite        WHERE methodology_version_id = @draft_id;
        DELETE FROM grac_practice.risk_methodology_impact_area     WHERE methodology_version_id = @draft_id;

        INSERT grac_practice.risk_methodology_dimension
            (methodology_version_id, dimension_code, dimension_name, description, is_enabled, is_required,
             ask_inherent, ask_residual, ask_review, priority_weight, display_order)
        SELECT @draft_id, code, name, descr, en, req, ai, ar, av, w, ord FROM @dims;

        INSERT grac_practice.risk_methodology_dimension_level
            (methodology_version_id, dimension_code, level_value, level_name, descriptor, colour_hex)
        SELECT @draft_id, code, lv, name, descr, colour FROM @levels;

        INSERT grac_practice.risk_methodology_score_band (methodology_version_id, min_score, max_score, rating_code)
        SELECT @draft_id, b.mn, b.mx, b.rc
          FROM OPENJSON(@payload, '$.bands')
               WITH (mn INT '$.minScore', mx INT '$.maxScore', rc NVARCHAR(30) '$.ratingCode') b
         WHERE b.mn IS NOT NULL AND b.mx IS NOT NULL AND b.rc IS NOT NULL;

        INSERT grac_practice.risk_methodology_appetite (methodology_version_id, risk_category_code, max_rating_code, appetite_statement)
        SELECT @draft_id, NULLIF(LTRIM(RTRIM(a.cat)), N''), a.rc, a.stmt
          FROM OPENJSON(@payload, '$.appetite')
               WITH (cat NVARCHAR(60) '$.riskCategoryCode', rc NVARCHAR(30) '$.maxRatingCode',
                     stmt NVARCHAR(1000) '$.appetiteStatement') a
         WHERE a.rc IS NOT NULL AND LEN(a.rc) > 0;

        INSERT grac_practice.risk_methodology_impact_area (methodology_version_id, area_code, area_name, display_order)
        SELECT @draft_id, UPPER(LTRIM(RTRIM(x.code))), LTRIM(RTRIM(x.name)), ISNULL(x.ord, 0)
          FROM OPENJSON(@payload, '$.impactAreas')
               WITH (code NVARCHAR(60) '$.areaCode', name NVARCHAR(200) '$.areaName', ord INT '$.displayOrder') x
         WHERE LEN(LTRIM(RTRIM(ISNULL(x.code, N'')))) > 0 AND LEN(LTRIM(RTRIM(ISNULL(x.name, N'')))) > 0;
    COMMIT;

    SELECT @draft_id AS MethodologyVersionId;
END;
GO

-- Validates the draft completely and makes it the current version.
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_methodology_publish
    @organization_id     BIGINT,
    @actor_employee_id   BIGINT        = NULL,
    @caller_display_name NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @draft_id BIGINT, @mode NVARCHAR(20), @third NVARCHAR(40), @quant BIT, @currency NVARCHAR(10);
    SELECT @draft_id = methodology_version_id, @mode = scoring_mode, @third = third_axis_code,
           @quant = quantification_enabled, @currency = currency_code
      FROM grac_practice.risk_methodology_version
     WHERE organization_id = @organization_id AND status = N'Draft';
    IF @draft_id IS NULL
        THROW 58318, 'There is no draft to publish.', 1;

    DECLARE @msg NVARCHAR(400);

    -- Every enabled dimension: at least two levels, asked at some stage.
    SELECT TOP (1) @msg = CONCAT(N'"', d.dimension_name, N'" needs at least two levels.')
      FROM grac_practice.risk_methodology_dimension d
     WHERE d.methodology_version_id = @draft_id AND d.is_enabled = 1
       AND (SELECT COUNT(*) FROM grac_practice.risk_methodology_dimension_level l
             WHERE l.methodology_version_id = @draft_id AND l.dimension_code = d.dimension_code) < 2;
    IF @msg IS NOT NULL THROW 58319, @msg, 1;

    SELECT TOP (1) @msg = CONCAT(N'"', d.dimension_name, N'" is switched on but no stage asks for it.')
      FROM grac_practice.risk_methodology_dimension d
     WHERE d.methodology_version_id = @draft_id AND d.is_enabled = 1
       AND d.ask_inherent = 0 AND d.ask_residual = 0 AND d.ask_review = 0;
    IF @msg IS NOT NULL THROW 58320, @msg, 1;

    IF @quant = 1 AND (@currency IS NULL OR LEN(@currency) = 0)
        THROW 58321, 'Quantification needs a currency.', 1;

    IF NOT EXISTS (SELECT 1 FROM grac_practice.risk_methodology_version
                    WHERE methodology_version_id = @draft_id AND LEN(ISNULL(methodology_name, N'')) > 0)
        THROW 58341, 'Give the methodology a name before publishing.', 1;

    IF EXISTS (SELECT 1 FROM grac_practice.risk_methodology_version
                WHERE methodology_version_id = @draft_id AND impact_mode IN (N'Max', N'Average'))
       AND NOT EXISTS (SELECT 1 FROM grac_practice.risk_methodology_impact_area WHERE methodology_version_id = @draft_id)
        THROW 58336, 'Impact by area needs at least one impact area.', 1;

    -- 3D: the third axis must be asked, and required, at every stage that
    -- produces a rating; the bands must cover 1 .. max L x max I x max level
    -- without gaps or overlaps, using the matrix's own ratings.
    IF @mode = N'3D'
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM grac_practice.risk_methodology_dimension
                        WHERE methodology_version_id = @draft_id AND dimension_code = @third
                          AND is_enabled = 1 AND is_required = 1
                          AND ask_inherent = 1 AND ask_residual = 1 AND ask_review = 1)
            THROW 58322, '3D scoring: the third dimension must be switched on, required, and asked at inherent, residual and review.', 1;

        DECLARE @max_score INT =
              (SELECT MAX(level_value) FROM grac_practice.risk_likelihood_master WHERE organization_id = @organization_id AND status = N'Active')
            * (SELECT MAX(level_value) FROM grac_practice.risk_impact_master     WHERE organization_id = @organization_id AND status = N'Active')
            * (SELECT MAX(level_value) FROM grac_practice.risk_methodology_dimension_level
                WHERE methodology_version_id = @draft_id AND dimension_code = @third);

        IF NOT EXISTS (SELECT 1 FROM grac_practice.risk_methodology_score_band WHERE methodology_version_id = @draft_id)
            THROW 58323, '3D scoring needs score bands.', 1;
        IF EXISTS (SELECT 1 FROM grac_practice.risk_methodology_score_band b
                    WHERE b.methodology_version_id = @draft_id
                      AND NOT EXISTS (SELECT 1 FROM grac_practice.risk_matrix_cell c
                                       WHERE c.organization_id = @organization_id AND c.rating_code = b.rating_code))
            THROW 58324, 'A score band uses a rating that is not in the risk matrix.', 1;
        IF EXISTS (SELECT 1 FROM grac_practice.risk_methodology_score_band a
                     JOIN grac_practice.risk_methodology_score_band b
                       ON b.methodology_version_id = a.methodology_version_id
                      AND b.methodology_band_id <> a.methodology_band_id
                      AND a.min_score <= b.max_score AND b.min_score <= a.max_score
                    WHERE a.methodology_version_id = @draft_id)
            THROW 58325, 'Two score bands overlap.', 1;
        IF (SELECT MIN(min_score) FROM grac_practice.risk_methodology_score_band WHERE methodology_version_id = @draft_id) <> 1
           OR (SELECT MAX(max_score) FROM grac_practice.risk_methodology_score_band WHERE methodology_version_id = @draft_id) < @max_score
           OR (SELECT SUM(max_score - min_score + 1) FROM grac_practice.risk_methodology_score_band WHERE methodology_version_id = @draft_id)
              <> (SELECT MAX(max_score) FROM grac_practice.risk_methodology_score_band WHERE methodology_version_id = @draft_id)
        BEGIN
            SET @msg = CONCAT(N'Score bands must cover every score from 1 to ', @max_score, N' with no gaps.');
            THROW 58326, @msg, 1;
        END
    END

    IF EXISTS (SELECT 1 FROM grac_practice.risk_methodology_appetite a
                WHERE a.methodology_version_id = @draft_id
                  AND NOT EXISTS (SELECT 1 FROM grac_practice.risk_matrix_cell c
                                   WHERE c.organization_id = @organization_id AND c.rating_code = a.max_rating_code))
        THROW 58327, 'An appetite uses a rating that is not in the risk matrix.', 1;
    IF EXISTS (SELECT 1 FROM grac_practice.risk_methodology_appetite a
                WHERE a.methodology_version_id = @draft_id AND a.risk_category_code IS NOT NULL
                  AND NOT EXISTS (SELECT 1 FROM grac_practice.risk_category_master c
                                   WHERE c.organization_id = @organization_id AND c.category_code = a.risk_category_code))
        THROW 58328, 'An appetite names a risk category this organization does not have.', 1;

    DECLARE @next_no INT = ISNULL((SELECT MAX(version_no) FROM grac_practice.risk_methodology_version
                                    WHERE organization_id = @organization_id), 0) + 1;
    BEGIN TRAN;
        UPDATE grac_practice.risk_methodology_version
           SET status = N'Superseded', updated_by = @caller_display_name, updated_dt = SYSUTCDATETIME()
         WHERE organization_id = @organization_id AND status = N'Published';
        UPDATE grac_practice.risk_methodology_version
           SET status = N'Published', version_no = @next_no,
               published_dt = SYSUTCDATETIME(), published_by_employee_id = @actor_employee_id,
               published_by_name = @caller_display_name,
               updated_by = @caller_display_name, updated_dt = SYSUTCDATETIME()
         WHERE methodology_version_id = @draft_id;
    COMMIT;

    SELECT @draft_id AS MethodologyVersionId, @next_no AS VersionNo;
END;
GO

-- =====================================================================
-- 8. sp_risk_methodology_assessment_save
--    Called by the Api right after the assessment's own save, in the
--    same transaction. Payload:
--      { methodologyVersionId, values: [{ dimensionCode, levelValue }],
--        impactAreas: [{ areaCode, impactCode }], targetRatingCode,
--        singleLossAmount, annualRate }
--    @source_code: Assess (inherent page), Review (review page),
--    Residual (residual page). The reference row defaults to the risk's
--    newest analysis / current residual analysis.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_methodology_assessment_save
    @risk_register_id          BIGINT,
    @source_code               NVARCHAR(20),
    @payload                   NVARCHAR(MAX),
    @risk_analysis_id          BIGINT        = NULL,
    @risk_residual_analysis_id BIGINT        = NULL,
    @actor_employee_id         BIGINT        = NULL,
    @caller_display_name       NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF @source_code NOT IN (N'Assess', N'Review', N'Residual')
        THROW 58329, 'Methodology source must be Assess, Review or Residual.', 1;
    IF @payload IS NULL OR ISJSON(@payload) = 0
        THROW 58309, 'The methodology payload is not valid JSON.', 1;

    DECLARE @org_id BIGINT = (SELECT organization_id FROM grac_practice.risk_register WHERE risk_register_id = @risk_register_id);
    IF @org_id IS NULL
        THROW 58330, 'Risk not found.', 1;

    DECLARE @mv_id BIGINT, @mode NVARCHAR(20), @third NVARCHAR(40), @target_on BIT,
            @impact_mode NVARCHAR(20), @quant BIT, @currency NVARCHAR(10);
    SELECT @mv_id = methodology_version_id, @mode = scoring_mode, @third = third_axis_code,
           @target_on = target_rating_enabled, @impact_mode = impact_mode,
           @quant = quantification_enabled, @currency = currency_code
      FROM grac_practice.risk_methodology_version
     WHERE organization_id = @org_id AND status = N'Published';
    IF @mv_id IS NULL
        THROW 58331, 'This organization has no published risk methodology.', 1;
    IF ISNULL(TRY_CONVERT(BIGINT, JSON_VALUE(@payload, '$.methodologyVersionId')), 0) <> @mv_id
        THROW 58332, 'The risk methodology was changed while this page was open. Reload the page and assess again.', 1;

    DECLARE @stage NVARCHAR(20) = CASE WHEN @source_code = N'Residual' THEN N'Residual' ELSE N'Inherent' END;
    DECLARE @lv INT, @iv INT, @eff NVARCHAR(30);

    IF @stage = N'Inherent'
    BEGIN
        IF @risk_analysis_id IS NULL
            SET @risk_analysis_id = (SELECT MAX(risk_analysis_id) FROM grac_practice.risk_analysis
                                      WHERE risk_register_id = @risk_register_id);
        SELECT @lv = likelihood_value, @iv = impact_value, @eff = inherent_rating_code
          FROM grac_practice.risk_analysis
         WHERE risk_analysis_id = @risk_analysis_id AND risk_register_id = @risk_register_id;
        IF @lv IS NULL THROW 58333, 'The assessment to attach the methodology to was not found.', 1;
    END
    ELSE
    BEGIN
        IF @risk_residual_analysis_id IS NULL
            SET @risk_residual_analysis_id = (SELECT TOP (1) risk_residual_analysis_id FROM grac_practice.risk_residual_analysis
                                               WHERE risk_register_id = @risk_register_id AND is_current = 1
                                               ORDER BY residual_version DESC);
        SELECT @lv = residual_likelihood_value, @iv = residual_impact_value, @eff = residual_rating_code
          FROM grac_practice.risk_residual_analysis
         WHERE risk_residual_analysis_id = @risk_residual_analysis_id AND risk_register_id = @risk_register_id;
        IF @lv IS NULL THROW 58333, 'The assessment to attach the methodology to was not found.', 1;
    END

    -- ---- dimension values: the stage's enabled dimensions only -------
    DECLARE @vals TABLE (code NVARCHAR(40), name NVARCHAR(120), lv INT, lname NVARCHAR(120), w DECIMAL(9,2), req BIT);
    INSERT @vals (code, name, w, req, lv)
    SELECT d.dimension_code, d.dimension_name, d.priority_weight, d.is_required,
           (SELECT TOP (1) TRY_CONVERT(INT, j.levelValue)
              FROM OPENJSON(@payload, '$.values')
                   WITH (dimensionCode NVARCHAR(40) '$.dimensionCode', levelValue NVARCHAR(20) '$.levelValue') j
             WHERE j.dimensionCode = d.dimension_code)
      FROM grac_practice.risk_methodology_dimension d
     WHERE d.methodology_version_id = @mv_id AND d.is_enabled = 1
       AND ((@source_code = N'Assess'   AND d.ask_inherent = 1)
         OR (@source_code = N'Review'   AND d.ask_review   = 1)
         OR (@source_code = N'Residual' AND d.ask_residual = 1));

    DECLARE @msg NVARCHAR(400);
    SELECT TOP (1) @msg = CONCAT(name, N' is required.') FROM @vals WHERE req = 1 AND lv IS NULL;
    IF @msg IS NOT NULL THROW 58334, @msg, 1;

    UPDATE v SET lname = l.level_name
      FROM @vals v
      JOIN grac_practice.risk_methodology_dimension_level l
        ON l.methodology_version_id = @mv_id AND l.dimension_code = v.code AND l.level_value = v.lv;
    SELECT TOP (1) @msg = CONCAT(N'Unknown level for ', name, N'.') FROM @vals WHERE lv IS NOT NULL AND lname IS NULL;
    IF @msg IS NOT NULL THROW 58335, @msg, 1;

    -- ---- impact areas -------------------------------------------------
    DECLARE @areas TABLE (code NVARCHAR(60), name NVARCHAR(200), lv INT, lname NVARCHAR(200));
    DECLARE @derived INT = NULL;
    IF @impact_mode IN (N'Max', N'Average')
    BEGIN
        INSERT @areas (code, name, lv, lname)
        SELECT a.area_code, a.area_name, im.level_value, im.impact_name
          FROM OPENJSON(@payload, '$.impactAreas')
               WITH (areaCode NVARCHAR(60) '$.areaCode', impactCode NVARCHAR(60) '$.impactCode') j
          JOIN grac_practice.risk_methodology_impact_area a
            ON a.methodology_version_id = @mv_id AND a.area_code = j.areaCode
          JOIN grac_practice.risk_impact_master im
            ON im.organization_id = @org_id AND im.impact_code = j.impactCode AND im.status = N'Active';
        IF NOT EXISTS (SELECT 1 FROM @areas)
            THROW 58336, 'Rate the impact for at least one impact area.', 1;
        SET @derived = CASE WHEN @impact_mode = N'Max' THEN (SELECT MAX(lv) FROM @areas)
                            ELSE (SELECT CAST(ROUND(AVG(CAST(lv AS DECIMAL(9,2))), 0) AS INT) FROM @areas) END;
        IF @derived <> @iv
            THROW 58337, 'The overall impact does not match the impact areas. Reload the page and assess again.', 1;
    END

    -- ---- target, quantification ---------------------------------------
    DECLARE @target NVARCHAR(30) = NULLIF(JSON_VALUE(@payload, '$.targetRatingCode'), N'');
    IF @target_on = 0 OR @stage = N'Residual' SET @target = NULL;
    IF @target IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.risk_matrix_cell
                                            WHERE organization_id = @org_id AND rating_code = @target)
        THROW 58338, 'The target rating is not one of this organization''s ratings.', 1;

    DECLARE @sle DECIMAL(19,2) = NULL, @aro DECIMAL(9,4) = NULL, @ale DECIMAL(19,2) = NULL;
    IF @quant = 1
    BEGIN
        SET @sle = TRY_CONVERT(DECIMAL(19,2), JSON_VALUE(@payload, '$.singleLossAmount'));
        SET @aro = TRY_CONVERT(DECIMAL(9,4),  JSON_VALUE(@payload, '$.annualRate'));
        IF @sle < 0 OR @aro < 0
            THROW 58339, 'Loss amount and annual rate cannot be negative.', 1;
        IF @sle IS NOT NULL AND @aro IS NOT NULL SET @ale = ROUND(@sle * @aro, 2);
    END

    -- ---- scores -------------------------------------------------------
    DECLARE @matrix NVARCHAR(30) = (SELECT rating_code FROM grac_practice.risk_matrix_cell
                                     WHERE organization_id = @org_id AND likelihood_value = @lv AND impact_value = @iv);
    DECLARE @score_3d INT = NULL, @priority DECIMAL(12,2) = NULL;
    IF @mode = N'3D'
        SET @score_3d = @lv * @iv * (SELECT lv FROM @vals WHERE code = @third);
    IF @mode = N'Priority'
        SET @priority = @lv * @iv + ISNULL((SELECT SUM(w * lv) FROM @vals WHERE lv IS NOT NULL), 0);

    DECLARE @id BIGINT;
    INSERT grac_practice.risk_assessment_methodology
        (organization_id, risk_register_id, stage_code, source_code, risk_analysis_id, risk_residual_analysis_id,
         methodology_version_id, scoring_mode, likelihood_value, impact_value, matrix_rating_code,
         effective_rating_code, score_3d, priority_score, target_rating_code, impact_mode, derived_impact_value,
         single_loss_amount, annual_rate, annual_loss_amount, currency_code, actor_employee_id, entered_by)
    VALUES
        (@org_id, @risk_register_id, @stage, @source_code,
         CASE WHEN @stage = N'Inherent' THEN @risk_analysis_id END,
         CASE WHEN @stage = N'Residual' THEN @risk_residual_analysis_id END,
         @mv_id, @mode, @lv, @iv, @matrix, @eff, @score_3d, @priority, @target, @impact_mode, @derived,
         @sle, @aro, @ale, CASE WHEN @quant = 1 THEN @currency END, @actor_employee_id, @caller_display_name);
    SET @id = SCOPE_IDENTITY();

    INSERT grac_practice.risk_assessment_dimension_value
        (assessment_methodology_id, value_kind, value_code, value_label, level_value, level_name)
    SELECT @id, N'Dimension', code, name, lv, lname FROM @vals WHERE lv IS NOT NULL
    UNION ALL
    SELECT @id, N'ImpactArea', code, name, lv, lname FROM @areas;

    SELECT @id AS AssessmentMethodologyId, @mv_id AS MethodologyVersionId,
           @score_3d AS Score3d, @priority AS PriorityScore, @ale AS AnnualLossAmount;
END;
GO

-- =====================================================================
-- 9. sp_risk_methodology_assessment_get -- one risk.
--    Set 1: the methodology rows behind the risk's APPLIED inherent
--    analysis, its CURRENT residual analysis and its NEWEST inherent
--    analysis (which may still await approval), with the version they
--    were made under. Set 2: their values.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_methodology_assessment_get
    @risk_register_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @applied BIGINT, @residual BIGINT, @newest BIGINT;
    SELECT @applied = risk_analysis_id, @residual = residual_analysis_id
      FROM grac_practice.risk_register WHERE risk_register_id = @risk_register_id;
    SET @newest = (SELECT MAX(risk_analysis_id) FROM grac_practice.risk_analysis WHERE risk_register_id = @risk_register_id);

    ;WITH pick AS (
        SELECT N'Inherent' AS Slot, MAX(assessment_methodology_id) AS id
          FROM grac_practice.risk_assessment_methodology WHERE risk_register_id = @risk_register_id AND risk_analysis_id = @applied
        UNION ALL
        SELECT N'Latest', MAX(assessment_methodology_id)
          FROM grac_practice.risk_assessment_methodology WHERE risk_register_id = @risk_register_id AND risk_analysis_id = @newest
        UNION ALL
        SELECT N'Residual', MAX(assessment_methodology_id)
          FROM grac_practice.risk_assessment_methodology WHERE risk_register_id = @risk_register_id AND risk_residual_analysis_id = @residual
    )
    SELECT p.Slot, m.assessment_methodology_id AS AssessmentMethodologyId, m.stage_code AS StageCode,
           m.source_code AS SourceCode, m.methodology_version_id AS MethodologyVersionId,
           v.version_no AS VersionNo, v.methodology_name AS MethodologyName, m.scoring_mode AS ScoringMode,
           m.matrix_rating_code AS MatrixRatingCode, m.effective_rating_code AS EffectiveRatingCode,
           m.score_3d AS Score3d, m.priority_score AS PriorityScore,
           m.target_rating_code AS TargetRatingCode, m.impact_mode AS ImpactMode,
           m.derived_impact_value AS DerivedImpactValue,
           m.single_loss_amount AS SingleLossAmount, m.annual_rate AS AnnualRate,
           m.annual_loss_amount AS AnnualLossAmount, m.currency_code AS CurrencyCode,
           m.entered_dt AS EnteredDt, m.entered_by AS EnteredBy
      FROM pick p
      JOIN grac_practice.risk_assessment_methodology m ON m.assessment_methodology_id = p.id
      JOIN grac_practice.risk_methodology_version v ON v.methodology_version_id = m.methodology_version_id;

    SELECT dv.assessment_methodology_id AS AssessmentMethodologyId, dv.value_kind AS ValueKind,
           dv.value_code AS ValueCode, dv.value_label AS ValueLabel,
           dv.level_value AS LevelValue, dv.level_name AS LevelName
      FROM grac_practice.risk_assessment_dimension_value dv
      JOIN grac_practice.risk_assessment_methodology m ON m.assessment_methodology_id = dv.assessment_methodology_id
     WHERE m.risk_register_id = @risk_register_id
       AND (m.risk_analysis_id IN (@applied, @newest) OR m.risk_residual_analysis_id = @residual)
     ORDER BY dv.assessment_methodology_id, dv.value_kind, dv.value_code;
END;
GO

-- =====================================================================
-- 10. sp_risk_methodology_register_summary -- one row per risk of the
--     organisation, for the register grid. Computed at read time, so it
--     always uses the CURRENT published version's appetite and trend
--     switches and the risk's CURRENT ratings.
--       CurrentRating   residual when the risk has one, else inherent
--       AppetiteStatus  Within | Above | NotSet (strictest appetite among
--                       the risk's categories, else the default row)
--       Trend           Up | Down | Same | New (current vs previous
--                       version of the same stage)
--     Set 2: the current assessment's dimension values per risk.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_methodology_register_summary
    @organization_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @mv_id BIGINT, @appetite_on BIT, @trend_on BIT, @target_on BIT;
    SELECT @mv_id = methodology_version_id, @appetite_on = appetite_enabled,
           @trend_on = trend_enabled, @target_on = target_rating_enabled
      FROM grac_practice.risk_methodology_version
     WHERE organization_id = @organization_id AND status = N'Published';

    ;WITH r AS (
        SELECT rr.risk_register_id, rr.risk_category_code, rr.status_code,
               rr.risk_analysis_id, rr.residual_analysis_id,
               COALESCE(rr.residual_rating_code, rr.inherent_rating_code) AS current_rating,
               CASE WHEN rr.residual_rating_code IS NOT NULL THEN N'Residual' ELSE N'Inherent' END AS current_stage
          FROM grac_practice.risk_register rr
         WHERE rr.organization_id = @organization_id
    ),
    cur AS (
        SELECT r.*,
               (SELECT MAX(m.assessment_methodology_id) FROM grac_practice.risk_assessment_methodology m
                 WHERE m.risk_register_id = r.risk_register_id
                   AND ((r.current_stage = N'Residual' AND m.risk_residual_analysis_id = r.residual_analysis_id)
                     OR (r.current_stage = N'Inherent' AND m.risk_analysis_id = r.risk_analysis_id))) AS cur_id,
               (SELECT MAX(m.assessment_methodology_id) FROM grac_practice.risk_assessment_methodology m
                 WHERE m.risk_register_id = r.risk_register_id AND m.risk_analysis_id = r.risk_analysis_id) AS inh_id
          FROM r
    )
    SELECT c.risk_register_id AS RiskRegisterId,
           c.status_code AS StatusCode,   -- the dashboard counts open risks only
           v.version_no AS VersionNo,
           c.current_stage AS CurrentStage,
           c.current_rating AS CurrentRatingCode,
           m.priority_score AS PriorityScore,
           m.score_3d AS Score3d,
           m.annual_loss_amount AS AnnualLossAmount,
           m.currency_code AS CurrencyCode,
           CASE WHEN @target_on = 1 THEN mi.target_rating_code END AS TargetRatingCode,
           CASE WHEN @target_on = 1 AND mi.target_rating_code IS NOT NULL AND c.current_stage = N'Residual'
                THEN CASE WHEN grac_practice.fn_risk_rating_rank(@organization_id, c.current_rating)
                               <= grac_practice.fn_risk_rating_rank(@organization_id, mi.target_rating_code)
                          THEN CAST(1 AS BIT) ELSE CAST(0 AS BIT) END END AS TargetMet,
           CASE WHEN ISNULL(@appetite_on, 0) = 0 THEN NULL ELSE ap.max_rating_code END AS AppetiteMaxRatingCode,
           CASE WHEN ISNULL(@appetite_on, 0) = 0 THEN NULL
                WHEN ap.max_rating_code IS NULL OR c.current_rating IS NULL THEN N'NotSet'
                WHEN grac_practice.fn_risk_rating_rank(@organization_id, c.current_rating)
                     > grac_practice.fn_risk_rating_rank(@organization_id, ap.max_rating_code) THEN N'Above'
                ELSE N'Within' END AS AppetiteStatus,
           CASE WHEN ISNULL(@trend_on, 0) = 0 THEN NULL
                WHEN prev.rating IS NULL THEN N'New'
                WHEN grac_practice.fn_risk_rating_rank(@organization_id, c.current_rating)
                     > grac_practice.fn_risk_rating_rank(@organization_id, prev.rating) THEN N'Up'
                WHEN grac_practice.fn_risk_rating_rank(@organization_id, c.current_rating)
                     < grac_practice.fn_risk_rating_rank(@organization_id, prev.rating) THEN N'Down'
                ELSE N'Same' END AS Trend,
           prev.rating AS PreviousRatingCode
      FROM cur c
      LEFT JOIN grac_practice.risk_assessment_methodology m  ON m.assessment_methodology_id  = c.cur_id
      LEFT JOIN grac_practice.risk_assessment_methodology mi ON mi.assessment_methodology_id = c.inh_id
      LEFT JOIN grac_practice.risk_methodology_version v ON v.methodology_version_id = m.methodology_version_id
      OUTER APPLY (
          -- strictest appetite among the risk's categories, else the default
          SELECT TOP (1) a.max_rating_code
            FROM grac_practice.risk_methodology_appetite a
           WHERE a.methodology_version_id = @mv_id
             AND (a.risk_category_code IS NULL
                  OR a.risk_category_code = c.risk_category_code
                  OR a.risk_category_code IN (SELECT cm.category_code
                                                FROM grac_practice.risk_register_risk_category rc
                                                JOIN grac_practice.risk_category_master cm
                                                  ON cm.risk_category_id = rc.risk_category_id
                                               WHERE rc.risk_register_id = c.risk_register_id))
           ORDER BY CASE WHEN a.risk_category_code IS NULL THEN 1 ELSE 0 END,
                    grac_practice.fn_risk_rating_rank(@organization_id, a.max_rating_code)
      ) ap
      OUTER APPLY (
          -- the previous version of the current stage
          SELECT TOP (1) x.rating
            FROM (SELECT ra.inherent_rating_code AS rating, ra.analysis_version AS ver
                    FROM grac_practice.risk_analysis ra
                   WHERE c.current_stage = N'Inherent' AND ra.risk_register_id = c.risk_register_id
                     AND ra.risk_analysis_id < c.risk_analysis_id AND ra.inherent_rating_code IS NOT NULL
                  UNION ALL
                  SELECT rs.residual_rating_code, rs.residual_version
                    FROM grac_practice.risk_residual_analysis rs
                   WHERE c.current_stage = N'Residual' AND rs.risk_register_id = c.risk_register_id
                     AND rs.risk_residual_analysis_id < c.residual_analysis_id AND rs.residual_rating_code IS NOT NULL) x
           ORDER BY x.ver DESC
      ) prev;

    SELECT m.risk_register_id AS RiskRegisterId, dv.value_code AS DimensionCode, dv.value_label AS DimensionName,
           dv.level_value AS LevelValue, dv.level_name AS LevelName
      FROM grac_practice.risk_register rr
      JOIN grac_practice.risk_assessment_methodology m
        ON m.assessment_methodology_id =
           (SELECT MAX(x.assessment_methodology_id) FROM grac_practice.risk_assessment_methodology x
             WHERE x.risk_register_id = rr.risk_register_id
               AND ((rr.residual_rating_code IS NOT NULL AND x.risk_residual_analysis_id = rr.residual_analysis_id)
                 OR (rr.residual_rating_code IS NULL     AND x.risk_analysis_id = rr.risk_analysis_id)))
      JOIN grac_practice.risk_assessment_dimension_value dv
        ON dv.assessment_methodology_id = m.assessment_methodology_id AND dv.value_kind = N'Dimension'
     WHERE rr.organization_id = @organization_id;
END;
GO

-- =====================================================================
-- 11. Menu: Settings -> Risk Methodology. Full permissions to the
--     organisation-administrator roles only (ORG_ADMIN, GRAC_ADMIN);
--     grant others in Role Menu Permissions if wanted.
-- =====================================================================
DECLARE @settings_id BIGINT = (SELECT menu_id FROM grac_practice.menu_master WHERE menu_key = N'nav-organization');
MERGE grac_practice.menu_master AS target
USING (VALUES
    (N'risk-methodology', N'Risk Methodology', N'Practice/Index/risk-methodology', 267, N'scale-balanced')
) AS src(menu_key, menu_name, menu_url, display_order, icon_class)
ON target.menu_key = src.menu_key
WHEN MATCHED THEN UPDATE SET
    menu_name = src.menu_name, menu_url = src.menu_url,
    parent_menu_id = @settings_id, display_order = src.display_order,
    icon_class = src.icon_class, module_type = N'Organization',
    status = N'Active', updated_by = 'seed-532', updated_dt = SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT
    (menu_key, menu_name, menu_url, parent_menu_id, display_order, icon_class, module_type, status, entered_by)
VALUES
    (src.menu_key, src.menu_name, src.menu_url, @settings_id, src.display_order,
     src.icon_class, N'Organization', N'Active', 'seed-532');
GO

DECLARE @active_rs INT = (
    SELECT TOP 1 record_status_id FROM grac_practice.record_status_master
     WHERE status_code = N'Active' OR status_name = N'Active' ORDER BY record_status_id);
IF @active_rs IS NULL SET @active_rs = 1;
INSERT grac_practice.organization_role_menu_permission
    (role_id, menu_id, can_view, can_add, can_edit, can_delete, can_approve,
     status, record_status_id, entered_by, entered_dt)
SELECT r.role_id, m.menu_id, 1, 1, 1, 1, 1,
       N'Active', @active_rs, N'seed-532', SYSUTCDATETIME()
FROM   grac_practice.organization_role r
JOIN   grac_practice.organization o ON o.organization_id = r.organization_id
JOIN   grac_practice.menu_master m ON m.menu_key = N'risk-methodology'
WHERE  o.status = N'Active' AND r.status = N'Active'
  AND  r.role_code IN (N'ORG_ADMIN', N'GRAC_ADMIN')
  AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_role_menu_permission p
                   WHERE p.role_id = r.role_id AND p.menu_id = m.menu_id);
PRINT '532: risk-methodology permission rows inserted = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

-- =====================================================================
-- 12. Verification
-- =====================================================================
SELECT '532 tables' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.risk_methodology_version','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.risk_methodology_dimension','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.risk_methodology_dimension_level','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.risk_methodology_score_band','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.risk_methodology_appetite','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.risk_assessment_methodology','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.risk_assessment_dimension_value','U') IS NOT NULL
             AND OBJECT_ID('grac_practice.risk_methodology_impact_area','U') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result_
UNION ALL SELECT '532 sp_risk_rating_resolve has the 3D block',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_risk_rating_resolve')) LIKE '%grac.risk.methodology%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT '532 procedures',
       CASE WHEN OBJECT_ID('grac_practice.sp_risk_methodology_get','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_risk_methodology_draft_create','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_risk_methodology_draft_save','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_risk_methodology_draft_discard','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_risk_methodology_publish','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_risk_methodology_assessment_save','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_risk_methodology_assessment_get','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_risk_methodology_register_summary','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT '532 menu row under Settings',
       CASE WHEN EXISTS (SELECT 1 FROM grac_practice.menu_master m
                           JOIN grac_practice.menu_master p ON p.menu_id = m.parent_menu_id
                          WHERE m.menu_key = N'risk-methodology' AND p.menu_key = N'nav-organization'
                            AND m.status = N'Active')
            THEN 'PASS' ELSE 'FAIL' END;
PRINT '532 complete. Restart the Api, deploy Web, then open Settings -> Risk Methodology.';
GO
SET NOEXEC OFF;
GO
