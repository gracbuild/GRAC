-- =====================================================================
-- 574 ROLLBACK  Risk methodology: likelihood, impact and the risk matrix
--   Restores the 532 bodies of the re-issued methodology procedures and
--   the 505 body of sp_risk_dashboard_counts; drops
--   fn_risk_scale_reassessment, sp_risk_methodology_core_fill,
--   risk_methodology_matrix_cell and risk_methodology_version.scale_changed;
--   removes the LIKELIHOOD / IMPACT level rows.
--   The organisation's masters and risk_matrix_cell stay as the last
--   publish left them (that is the scale the risks were rated on).
-- SAFE TO RE-RUN. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

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

CREATE OR ALTER PROCEDURE grac_practice.sp_risk_dashboard_counts
    @organization_id BIGINT,
    @trend_months    INT = 12
AS
BEGIN
    SET NOCOUNT ON;

    IF @organization_id IS NULL
        THROW 56350, 'sp_risk_dashboard_counts: organization_id is required.', 1;
    IF @trend_months IS NULL OR @trend_months <= 0 SET @trend_months = 12;
    IF @trend_months > 60 SET @trend_months = 60;

    -- The statuses a candidate is still being worked in. Declared once
    -- so every tile below counts "open" the same way -- the Candidates
    -- grid, the approval queue and this dashboard must not disagree
    -- about what is outstanding.
    DECLARE @open TABLE (status_code NVARCHAR(30) PRIMARY KEY);
    INSERT INTO @open(status_code)
    VALUES (N'Pending'), (N'UnderAnalysis'), (N'ClarificationRequired'), (N'AnalysisCompleted');

    -- WHY THE "OPEN" TEST IS A JOIN AND NOT AN IN (SELECT ...)
    -- -------------------------------------------------------
    -- SQL Server rejects a subquery inside an aggregate (Msg 130), so
    -- SUM(CASE WHEN status IN (SELECT ... FROM @open) ...) will not
    -- compile. The obvious workaround -- inlining the four literals at
    -- every call site -- would defeat the point of declaring the set
    -- once, and is exactly how the dashboard and the grids drift apart.
    --
    -- So the openness test is resolved ONCE, in a LEFT JOIN, and every
    -- aggregate then works on a plain 0/1 column. One definition, and it
    -- compiles.
    --
    -- The @open set is also used in WHERE clauses further down (result
    -- sets 0's approval subquery and 8's ageing CTE). That form is legal
    -- -- the restriction is aggregate-of-subquery, not subquery-anywhere.

    -- ---- 0. Candidate summary (sec.23) ----------------------------------
    ;WITH cand AS (
        SELECT c.status_code,
               CASE WHEN o.status_code IS NULL THEN 0 ELSE 1 END AS is_open,
               DATEDIFF(DAY, COALESCE(c.identified_dt, c.requested_dt), SYSUTCDATETIME()) AS age_days
          FROM grac_practice.risk_candidate c
     LEFT JOIN @open o ON o.status_code = c.status_code
         WHERE c.organization_id = @organization_id
    )
    SELECT
        COUNT(*)                                                                 AS TotalCandidates,
        SUM(is_open)                                                             AS OpenCandidates,
        SUM(CASE WHEN status_code = N'Pending'               THEN 1 ELSE 0 END)  AS NewCandidates,
        SUM(CASE WHEN status_code = N'UnderAnalysis'         THEN 1 ELSE 0 END)  AS UnderAnalysisCount,
        SUM(CASE WHEN status_code = N'ClarificationRequired' THEN 1 ELSE 0 END)  AS AwaitingClarificationCount,
        -- "Awaiting approval" is the analysis-level fact, not a candidate
        -- status: a candidate sits in AnalysisCompleted whether or not
        -- anyone has submitted it. Counting the status would overstate
        -- the approver's queue.
        --
        -- A scalar subquery in the SELECT list is fine; it is only
        -- aggregates that may not contain one.
        (SELECT COUNT(*) FROM grac_practice.risk_analysis a
           JOIN grac_practice.risk_candidate ac ON ac.risk_candidate_id = a.risk_candidate_id
          WHERE a.organization_id = @organization_id
            AND a.is_current = 1
            AND a.approval_status_code = N'Pending'
            AND ac.status_code IN (SELECT status_code FROM @open))               AS AwaitingApprovalCount,
        SUM(CASE WHEN status_code = N'AnalysisCompleted'     THEN 1 ELSE 0 END)  AS AnalysisCompletedCount,
        SUM(CASE WHEN status_code = N'Rejected'              THEN 1 ELSE 0 END)  AS RejectedCount,
        SUM(CASE WHEN status_code = N'ClosedAsDuplicate'     THEN 1 ELSE 0 END)  AS ClosedAsDuplicateCount,
        SUM(CASE WHEN status_code = N'Withdrawn'             THEN 1 ELSE 0 END)  AS WithdrawnCount,
        SUM(CASE WHEN status_code = N'Registered'            THEN 1 ELSE 0 END)  AS ConvertedToRiskCount,
        SUM(CASE WHEN status_code = N'Accepted'              THEN 1 ELSE 0 END)  AS LegacyAcceptedCount,
        -- Ageing of what is still open, measured from identification
        -- (sec.6.2) rather than triage -- see 205's note on identified_dt.
        AVG(CASE WHEN is_open = 1 THEN age_days END)                             AS AvgOpenAgeDays,
        MAX(CASE WHEN is_open = 1 THEN age_days END)                             AS MaxOpenAgeDays
      FROM cand;

    -- ---- 1. Candidates by source (sec.23) -------------------------------
    ;WITH cand_src AS (
        SELECT c.source_type_code,
               ISNULL(s.source_name, c.source_type_code) AS source_name,
               c.status_code,
               CASE WHEN o.status_code IS NULL THEN 0 ELSE 1 END AS is_open
          FROM grac_practice.risk_candidate c
     LEFT JOIN grac_practice.risk_source_master s ON s.source_type_code = c.source_type_code
     LEFT JOIN @open o ON o.status_code = c.status_code
         WHERE c.organization_id = @organization_id
    )
    SELECT
        source_type_code   AS SourceTypeCode,
        MAX(source_name)   AS SourceName,
        COUNT(*)           AS TotalCount,
        SUM(is_open)       AS OpenCount,
        SUM(CASE WHEN status_code = N'Registered' THEN 1 ELSE 0 END) AS RegisteredCount,
        SUM(CASE WHEN status_code IN (N'Rejected', N'ClosedAsDuplicate', N'Withdrawn')
                 THEN 1 ELSE 0 END) AS ClosedCount
      FROM cand_src
     GROUP BY source_type_code
     ORDER BY COUNT(*) DESC;

    -- ---- 2. Register summary (sec.23) -----------------------------------
    -- "High/Critical risks" (sec.23). Resolved through the org's OWN matrix
    -- rather than string-matching 'High'/'Critical', so a framework using
    -- colour bands or 1-4 still gets a meaningful number. The threshold
    -- is the midpoint of this organisation's own rating scores.
    --
    -- Computed into a variable rather than written inline, for the same
    -- Msg 130 reason as the openness test above: a subquery may not sit
    -- inside SUM(). An organisation with no matrix yet leaves this NULL,
    -- and the comparison below then yields 0 rather than failing.
    DECLARE @elevated_threshold INT =
        (SELECT (MIN(rating_score) + MAX(rating_score)) / 2
           FROM grac_practice.risk_matrix_cell
          WHERE organization_id = @organization_id);

    SELECT
        COUNT(*)                                                              AS TotalRisks,
        SUM(CASE WHEN r.status_code = N'Active'         THEN 1 ELSE 0 END)     AS ActiveCount,
        SUM(CASE WHEN r.status_code = N'UnderTreatment' THEN 1 ELSE 0 END)     AS UnderTreatmentCount,
        SUM(CASE WHEN r.status_code = N'Accepted'       THEN 1 ELSE 0 END)     AS AcceptedCount,
        SUM(CASE WHEN r.status_code = N'Monitoring'     THEN 1 ELSE 0 END)     AS MonitoringCount,
        SUM(CASE WHEN r.status_code = N'Closed'         THEN 1 ELSE 0 END)     AS ClosedCount,
        SUM(CASE WHEN r.status_code = N'Retired'        THEN 1 ELSE 0 END)     AS RetiredCount,
        SUM(CASE WHEN @elevated_threshold IS NOT NULL
                       AND r.inherent_rating_score >= @elevated_threshold
                 THEN 1 ELSE 0 END)                                            AS ElevatedRatingCount,
        SUM(CASE WHEN r.source_type_code = N'Custom' THEN 1 ELSE 0 END)        AS CustomRiskCount,
        SUM(CASE WHEN r.risk_owner_employee_id IS NULL THEN 1 ELSE 0 END)      AS UnownedCount,
        AVG(CAST(r.inherent_rating_score AS FLOAT))                            AS AvgInherentScore
      FROM grac_practice.risk_register r
     WHERE r.organization_id = @organization_id;

    -- ---- 3. Risks by category (sec.23) ----------------------------------
    SELECT
        ISNULL(r.risk_category_code, N'(uncategorised)') AS CategoryCode,
        ISNULL(r.risk_category_name, N'(uncategorised)') AS CategoryName,
        COUNT(*)                                          AS TotalCount,
        SUM(CASE WHEN r.status_code IN (N'Closed', N'Retired') THEN 0 ELSE 1 END) AS OpenCount,
        AVG(CAST(r.inherent_rating_score AS FLOAT))       AS AvgInherentScore
      FROM grac_practice.risk_register r
     WHERE r.organization_id = @organization_id
     GROUP BY r.risk_category_code, r.risk_category_name
     ORDER BY COUNT(*) DESC;

    -- ---- 4. Risks by source (sec.23) ------------------------------------
    SELECT
        r.source_type_code AS SourceTypeCode,
        MAX(ISNULL(s.source_name, r.source_type_code)) AS SourceName,
        COUNT(*)           AS TotalCount,
        SUM(CASE WHEN r.status_code IN (N'Closed', N'Retired') THEN 0 ELSE 1 END) AS OpenCount
      FROM grac_practice.risk_register r
 LEFT JOIN grac_practice.risk_source_master s ON s.source_type_code = r.source_type_code
     WHERE r.organization_id = @organization_id
     GROUP BY r.source_type_code
     ORDER BY COUNT(*) DESC;

    -- ---- 5. Risks by rating (sec.23) ------------------------------------
    -- Ordered by the org's own score, not alphabetically, so the heat
    -- reads top-down whatever the rating words are.
    SELECT
        ISNULL(r.inherent_rating_code, N'(unrated)') AS RatingCode,
        ISNULL(r.inherent_rating_name, N'(unrated)') AS RatingName,
        MAX(r.inherent_rating_score)                  AS RatingScore,
        MAX(m.colour_hex)                             AS ColourHex,
        COUNT(*)                                      AS TotalCount,
        SUM(CASE WHEN r.status_code IN (N'Closed', N'Retired') THEN 0 ELSE 1 END) AS OpenCount
      FROM grac_practice.risk_register r
 LEFT JOIN grac_practice.risk_matrix_cell m
        ON m.organization_id  = r.organization_id
       AND m.likelihood_value = r.likelihood_value
       AND m.impact_value     = r.impact_value
     WHERE r.organization_id = @organization_id
     GROUP BY r.inherent_rating_code, r.inherent_rating_name
     ORDER BY MAX(r.inherent_rating_score) DESC;

    -- ---- 6. Risks by business unit (sec.23) -----------------------------
    SELECT
        ISNULL(r.business_unit, N'(unassigned)') AS BusinessUnit,
        COUNT(*)                                  AS TotalCount,
        SUM(CASE WHEN r.status_code IN (N'Closed', N'Retired') THEN 0 ELSE 1 END) AS OpenCount,
        AVG(CAST(r.inherent_rating_score AS FLOAT)) AS AvgInherentScore
      FROM grac_practice.risk_register r
     WHERE r.organization_id = @organization_id
     GROUP BY r.business_unit
     ORDER BY COUNT(*) DESC;

    -- ---- 7. Risks by owner (sec.23) -------------------------------------
    SELECT
        r.risk_owner_employee_id                  AS OwnerEmployeeId,
        ISNULL(e.employee_name, N'(unassigned)')  AS OwnerName,
        COUNT(*)                                  AS TotalCount,
        SUM(CASE WHEN r.status_code IN (N'Closed', N'Retired') THEN 0 ELSE 1 END) AS OpenCount,
        AVG(CAST(r.inherent_rating_score AS FLOAT)) AS AvgInherentScore
      FROM grac_practice.risk_register r
 LEFT JOIN grac_practice.organization_employee e ON e.employee_id = r.risk_owner_employee_id
     WHERE r.organization_id = @organization_id
     GROUP BY r.risk_owner_employee_id, e.employee_name
     ORDER BY COUNT(*) DESC;

    -- ---- 8. Candidate ageing bands (sec.23 "Candidate ageing") ----------
    -- Only OPEN candidates age. A rejected candidate from last March is
    -- not "180 days old and getting older" -- it is finished, and putting
    -- it in an ageing chart makes the backlog look permanently terrible.
    ;WITH aged AS (
        SELECT c.risk_candidate_id,
               DATEDIFF(DAY, COALESCE(c.identified_dt, c.requested_dt), SYSUTCDATETIME()) AS age_days
          FROM grac_practice.risk_candidate c
         WHERE c.organization_id = @organization_id
           AND c.status_code IN (SELECT status_code FROM @open)
    )
    -- 413: the band's own day range is returned too, so a click on the
    -- band filters the Candidates list by exactly these days.
    SELECT b.BandCode, b.BandName, b.SortOrder,
           COUNT(a.risk_candidate_id) AS CandidateCount,
           b.LowDays  AS MinAgeDays,
           b.HighDays AS MaxAgeDays
      FROM (VALUES
              (N'0_7',    N'0-7 days',    1, 0,   7),
              (N'8_30',   N'8-30 days',   2, 8,   30),
              (N'31_90',  N'31-90 days',  3, 31,  90),
              (N'91_180', N'91-180 days', 4, 91,  180),
              (N'180_',   N'Over 180 days', 5, 181, 100000)
           ) AS b(BandCode, BandName, SortOrder, LowDays, HighDays)
 LEFT JOIN aged a ON a.age_days BETWEEN b.LowDays AND b.HighDays
     GROUP BY b.BandCode, b.BandName, b.SortOrder, b.LowDays, b.HighDays
     ORDER BY b.SortOrder;

    -- ---- 9. Risk trend (sec.23) -----------------------------------------
    -- Registrations and closures per month. Both, because a rising
    -- registration count alone says nothing -- a register that gains 10
    -- and closes 12 is improving, and a trend line that hides the second
    -- number invites the wrong conclusion.
    ;WITH months AS (
        SELECT DATEFROMPARTS(YEAR(SYSUTCDATETIME()), MONTH(SYSUTCDATETIME()), 1) AS month_start, 0 AS n
        UNION ALL
        SELECT DATEADD(MONTH, -1, month_start), n + 1 FROM months WHERE n < @trend_months - 1
    )
    SELECT
        m.month_start AS MonthStart,
        (SELECT COUNT(*) FROM grac_practice.risk_register r
          WHERE r.organization_id = @organization_id
            AND r.registered_dt >= m.month_start
            AND r.registered_dt <  DATEADD(MONTH, 1, m.month_start))            AS RegisteredCount,
        (SELECT COUNT(*) FROM grac_practice.risk_register r
          WHERE r.organization_id = @organization_id
            AND r.closed_dt IS NOT NULL
            AND r.closed_dt >= m.month_start
            AND r.closed_dt <  DATEADD(MONTH, 1, m.month_start))                AS ClosedCount,
        (SELECT COUNT(*) FROM grac_practice.risk_candidate c
          WHERE c.organization_id = @organization_id
            AND COALESCE(c.identified_dt, c.requested_dt) >= m.month_start
            AND COALESCE(c.identified_dt, c.requested_dt) <  DATEADD(MONTH, 1, m.month_start))
                                                                                AS CandidatesRaisedCount
      FROM months m
     ORDER BY m.month_start
     OPTION (MAXRECURSION 100);

    -- ---- 10. Overdue risk actions (sec.23) ------------------------------
    -- Read from Task Centre's own view -- see the header note on why this
    -- does not recompute overdue-ness. Degrades to an empty set when
    -- Task Centre is not installed, so the dashboard still paints.
    IF OBJECT_ID('grac_practice.vw_pm_practice_task', 'V') IS NOT NULL
        EXEC sp_executesql N'
            SELECT v.task_id             AS TaskId,
                   v.task_number         AS TaskNumber,
                   v.subject_title       AS TaskTitle,
                   v.source_record_id    AS RiskCandidateId,
                   v.assigned_to_employee_name AS OwnerName,
                   v.priority            AS Priority,
                   v.sla_due_at          AS DueAt,
                   v.sla_status_code     AS SlaStatusCode,
                   v.current_status_name AS TaskStatusName
              FROM grac_practice.vw_pm_practice_task v
             WHERE v.organization_id  = @org
               AND v.source_type_code = N''Risk''
               AND v.completed_dt IS NULL
               AND v.sla_status_code IN (N''Breached'', N''DueToday'', N''DueSoon'')
             ORDER BY v.sla_due_at;',
            N'@org BIGINT', @org = @organization_id;
    ELSE
        SELECT CAST(NULL AS BIGINT)       AS TaskId,
               CAST(NULL AS NVARCHAR(60)) AS TaskNumber,
               CAST(NULL AS NVARCHAR(250))AS TaskTitle,
               CAST(NULL AS BIGINT)       AS RiskCandidateId,
               CAST(NULL AS NVARCHAR(240))AS OwnerName,
               CAST(NULL AS NVARCHAR(30)) AS Priority,
               CAST(NULL AS DATETIME2)    AS DueAt,
               CAST(NULL AS NVARCHAR(30)) AS SlaStatusCode,
               CAST(NULL AS NVARCHAR(120))AS TaskStatusName
         WHERE 1 = 0;

    -- =================================================================
    -- 413: Risk Management dashboard. Six result sets APPENDED after
    -- set 10, as 214's header requires -- every reader of sets 0-10 is
    -- untouched. "Open" for a registered risk is the rule sets 3-7
    -- already use: status_code NOT IN ('Closed','Retired').
    -- =================================================================

    -- ---- 11. Matrix axes -------------------------------------------
    -- The organisation's OWN scale: every likelihood and impact value
    -- its risk_matrix_cell grid uses, named from the scoring masters
    -- (204). Axis 'L' = likelihood, 'I' = impact.
    SELECT ax.Axis, ax.LevelValue,
           MAX(ax.LevelCode) AS LevelCode,
           MAX(ax.LevelName) AS LevelName
      FROM (
            SELECT N'L' AS Axis, m.likelihood_value AS LevelValue,
                   lm.likelihood_code AS LevelCode,
                   ISNULL(lm.likelihood_name, CAST(m.likelihood_value AS NVARCHAR(20))) AS LevelName
              FROM grac_practice.risk_matrix_cell m
         LEFT JOIN grac_practice.risk_likelihood_master lm
                ON lm.organization_id = m.organization_id
               AND lm.level_value     = m.likelihood_value
             WHERE m.organization_id = @organization_id
            UNION ALL
            SELECT N'I', m.impact_value,
                   im.impact_code,
                   ISNULL(im.impact_name, CAST(m.impact_value AS NVARCHAR(20)))
              FROM grac_practice.risk_matrix_cell m
         LEFT JOIN grac_practice.risk_impact_master im
                ON im.organization_id = m.organization_id
               AND im.level_value     = m.impact_value
             WHERE m.organization_id = @organization_id
           ) ax
     GROUP BY ax.Axis, ax.LevelValue
     ORDER BY ax.Axis, ax.LevelValue;

    -- ---- 12. Inherent heatmap --------------------------------------
    -- One row per matrix cell. The cell's rating is the matrix's own
    -- (the scale sp_risk_rating_resolve reads); RiskCount is the open
    -- risks whose INHERENT likelihood x impact land on it.
    SELECT m.likelihood_value AS LikelihoodValue,
           m.impact_value     AS ImpactValue,
           m.rating_code      AS RatingCode,
           m.rating_name      AS RatingName,
           m.rating_score     AS RatingScore,
           m.colour_hex       AS ColourHex,
           (SELECT COUNT(*) FROM grac_practice.risk_register r
             WHERE r.organization_id  = @organization_id
               AND r.status_code NOT IN (N'Closed', N'Retired')
               AND r.likelihood_value = m.likelihood_value
               AND r.impact_value     = m.impact_value) AS RiskCount
      FROM grac_practice.risk_matrix_cell m
     WHERE m.organization_id = @organization_id
     ORDER BY m.likelihood_value, m.impact_value;

    -- ---- 13. Residual heatmap --------------------------------------
    -- Same matrix, the RESIDUAL likelihood x impact (258). A risk with
    -- no residual assessment yet has NULL residual values and is not
    -- plotted; set 14 counts those separately.
    SELECT m.likelihood_value AS LikelihoodValue,
           m.impact_value     AS ImpactValue,
           m.rating_code      AS RatingCode,
           m.rating_name      AS RatingName,
           m.rating_score     AS RatingScore,
           m.colour_hex       AS ColourHex,
           (SELECT COUNT(*) FROM grac_practice.risk_register r
             WHERE r.organization_id           = @organization_id
               AND r.status_code NOT IN (N'Closed', N'Retired')
               AND r.residual_likelihood_value = m.likelihood_value
               AND r.residual_impact_value     = m.impact_value) AS RiskCount
      FROM grac_practice.risk_matrix_cell m
     WHERE m.organization_id = @organization_id
     ORDER BY m.likelihood_value, m.impact_value;

    -- ---- 14. Heatmap coverage --------------------------------------
    -- How many open risks each map shows, and how many it cannot: a
    -- heatmap that silently drops unrated risks overstates coverage.
    SELECT COUNT(*) AS OpenRisks,
           SUM(CASE WHEN r.likelihood_value IS NOT NULL AND r.impact_value IS NOT NULL
                    THEN 1 ELSE 0 END) AS InherentRated,
           SUM(CASE WHEN r.residual_likelihood_value IS NOT NULL AND r.residual_impact_value IS NOT NULL
                    THEN 1 ELSE 0 END) AS ResidualRated,
           SUM(CASE WHEN ISNULL(r.residual_pending, 1) = 1 THEN 1 ELSE 0 END) AS ResidualPending
      FROM grac_practice.risk_register r
     WHERE r.organization_id = @organization_id
       AND r.status_code NOT IN (N'Closed', N'Retired');

    -- ---- 15. Review ageing -----------------------------------------
    -- Pending and overdue reviews only, on the rule
    -- vw_pm_risk_workflow_stage.is_review_due and sp_risk_review_due_list
    -- use: open risk, next_review_date set; due when it is on or before
    -- today. DaysOverdue = today - next_review_date (negative = still
    -- upcoming). The overdue bands are 214 set 8's bands; the two
    -- upcoming bands match the Review Risk horizon (7 / 30 days).
    DECLARE @today413 DATE = CAST(SYSUTCDATETIME() AS DATE);
    ;WITH rv AS (
        SELECT DATEDIFF(DAY, r.next_review_date, @today413) AS days_overdue
          FROM grac_practice.risk_register r
         WHERE r.organization_id = @organization_id
           AND r.next_review_date IS NOT NULL
           AND r.status_code NOT IN (N'Closed', N'Retired')
    )
    SELECT b.BandCode, b.BandName, b.BandGroup, b.SortOrder,
           b.MinDaysOverdue, b.MaxDaysOverdue,
           COUNT(rv.days_overdue) AS RiskCount
      FROM (VALUES
              (N'due_8_30', N'Due in 8-30 days', N'Pending', 1, -30,  -8),
              (N'due_1_7',  N'Due in 1-7 days',  N'Pending', 2, -7,   -1),
              (N'0_7',      N'0-7 days',         N'Overdue', 3,  0,    7),
              (N'8_30',     N'8-30 days',        N'Overdue', 4,  8,   30),
              (N'31_90',    N'31-90 days',       N'Overdue', 5, 31,   90),
              (N'91_180',   N'91-180 days',      N'Overdue', 6, 91,  180),
              (N'180_',     N'Over 180 days',    N'Overdue', 7, 181, 100000)
           ) AS b(BandCode, BandName, BandGroup, SortOrder, MinDaysOverdue, MaxDaysOverdue)
 LEFT JOIN rv ON rv.days_overdue BETWEEN b.MinDaysOverdue AND b.MaxDaysOverdue
     GROUP BY b.BandCode, b.BandName, b.BandGroup, b.SortOrder, b.MinDaysOverdue, b.MaxDaysOverdue
     ORDER BY b.SortOrder;

    -- ---- 16. Top risks by rating ---------------------------------
    -- Open risks, highest INHERENT score first (the score every "by
    -- rating" set above already ranks by), then residual score, then
    -- the older registration, then the id -- so two equal risks never
    -- swap places between refreshes.
    -- 505: TOP (10) (was 5) + WorkflowStageCode, NextReviewDate (columns
    -- appended; readers use names).
    SELECT TOP (10)
           r.risk_register_id       AS RiskRegisterId,
           r.risk_number            AS RiskNumber,
           r.risk_title             AS RiskTitle,
           r.risk_owner_employee_id AS RiskOwnerEmployeeId,
           ow.employee_name         AS RiskOwnerName,
           r.inherent_rating_code   AS InherentRatingCode,
           r.inherent_rating_name   AS InherentRatingName,
           r.inherent_rating_score  AS InherentRatingScore,
           r.residual_rating_code   AS ResidualRatingCode,
           r.residual_rating_name   AS ResidualRatingName,
           r.residual_rating_score  AS ResidualRatingScore,
           r.status_code            AS StatusCode,
           st.workflow_stage_code   AS WorkflowStageCode,
           r.next_review_date       AS NextReviewDate
      FROM grac_practice.risk_register r
 LEFT JOIN grac_practice.organization_employee ow ON ow.employee_id = r.risk_owner_employee_id
 LEFT JOIN grac_practice.vw_pm_risk_workflow_stage st ON st.risk_register_id = r.risk_register_id
     WHERE r.organization_id = @organization_id
       AND r.status_code NOT IN (N'Closed', N'Retired')
     ORDER BY CASE WHEN r.inherent_rating_score IS NULL THEN 1 ELSE 0 END,
              r.inherent_rating_score DESC,
              CASE WHEN r.residual_rating_score IS NULL THEN 1 ELSE 0 END,
              r.residual_rating_score DESC,
              r.registered_dt ASC,
              r.risk_register_id ASC;

    -- =================================================================
    -- 505: Dashboard UI specification v2 (section 8). Three result sets
    -- APPENDED after set 16 -- every reader of sets 0-16 is untouched.
    -- Open = status_code NOT IN ('Closed','Retired'), as above.
    -- =================================================================

    -- ---- 17. Open risks by workflow stage ---------------------------
    -- The Risk Register's own stage (vw_pm_risk_workflow_stage, 299/484)
    -- -- the value its "Workflow stage" filter takes -- every stage
    -- listed, zero included, in lifecycle order. ReviewDue outranks the
    -- other stages in the view, exactly as on the register.
    SELECT s.StageCode, s.StageName,
           COUNT(x.risk_register_id) AS TotalCount,
           COUNT(x.risk_register_id) AS OpenCount
      FROM (VALUES (N'AnalysisDue',   N'Analysis due',           1),
                   (N'TreatmentDue',  N'Treatment option due',   2),
                   (N'InTreatment',   N'In treatment',           3),
                   (N'ResidualDue',   N'Residual analysis due',  4),
                   (N'AcceptanceDue', N'Acceptance due',         5),
                   (N'Accepted',      N'Accepted',               6),
                   (N'ReviewDue',     N'Review due',             7)) s(StageCode, StageName, SortOrder)
 LEFT JOIN (SELECT r.risk_register_id, st.workflow_stage_code
              FROM grac_practice.risk_register r
              JOIN grac_practice.vw_pm_risk_workflow_stage st ON st.risk_register_id = r.risk_register_id
             WHERE r.organization_id = @organization_id
               AND r.status_code NOT IN (N'Closed', N'Retired')) x
        ON x.workflow_stage_code = s.StageCode
     GROUP BY s.StageCode, s.StageName, s.SortOrder
     ORDER BY s.SortOrder;

    -- ---- 18. Open risks by treatment option -------------------------
    -- treatment_option_code as recorded (the register's Treatment
    -- option filter values); NULL = no option decided yet.
    SELECT ISNULL(r.treatment_option_code, N'')                 AS TreatmentOptionCode,
           CASE r.treatment_option_code
                WHEN N'Terminate' THEN N'Terminate / Avoid'
                WHEN N'Treat'     THEN N'Treat / Reduce'
                WHEN N'Transfer'  THEN N'Transfer / Share'
                WHEN N'Tolerate'  THEN N'Tolerate / Accept'
                ELSE ISNULL(r.treatment_option_code, N'Not decided') END AS TreatmentOptionName,
           COUNT(*) AS TotalCount,
           COUNT(*) AS OpenCount
      FROM grac_practice.risk_register r
     WHERE r.organization_id = @organization_id
       AND r.status_code NOT IN (N'Closed', N'Retired')
     GROUP BY r.treatment_option_code
     ORDER BY CASE r.treatment_option_code WHEN N'Terminate' THEN 1 WHEN N'Treat' THEN 2
                                           WHEN N'Transfer' THEN 3 WHEN N'Tolerate' THEN 4 ELSE 5 END;

    -- ---- 19. Open risks by residual rating --------------------------
    -- Assessed residual ratings only (the residual columns, 258); risks
    -- awaiting residual assessment are counted in set 14, never folded
    -- into a rating. Colour = the matrix cell the residual lands on.
    SELECT r.residual_rating_code       AS RatingCode,
           MAX(r.residual_rating_name)  AS RatingName,
           MAX(r.residual_rating_score) AS RatingScore,
           MAX(m.colour_hex)            AS ColourHex,
           COUNT(*)                     AS TotalCount,
           COUNT(*)                     AS OpenCount
      FROM grac_practice.risk_register r
 LEFT JOIN grac_practice.risk_matrix_cell m
        ON m.organization_id  = r.organization_id
       AND m.likelihood_value = r.residual_likelihood_value
       AND m.impact_value     = r.residual_impact_value
     WHERE r.organization_id = @organization_id
       AND r.status_code NOT IN (N'Closed', N'Retired')
       AND r.residual_rating_code IS NOT NULL
     GROUP BY r.residual_rating_code
     ORDER BY MAX(r.residual_rating_score) DESC;
END;
GO

DROP FUNCTION IF EXISTS grac_practice.fn_risk_scale_reassessment;
DROP PROCEDURE IF EXISTS grac_practice.sp_risk_methodology_core_fill;
GO
IF OBJECT_ID('grac_practice.risk_methodology_matrix_cell','U') IS NOT NULL
    DROP TABLE grac_practice.risk_methodology_matrix_cell;
IF OBJECT_ID('grac_practice.risk_methodology_dimension_level','U') IS NOT NULL
    DELETE FROM grac_practice.risk_methodology_dimension_level WHERE dimension_code IN (N'LIKELIHOOD', N'IMPACT');
GO
IF COL_LENGTH('grac_practice.risk_methodology_version','scale_changed') IS NOT NULL
BEGIN
    IF OBJECT_ID('grac_practice.df_pm_rmv_scale_changed','D') IS NOT NULL
        ALTER TABLE grac_practice.risk_methodology_version DROP CONSTRAINT df_pm_rmv_scale_changed;
    ALTER TABLE grac_practice.risk_methodology_version DROP COLUMN scale_changed;
END
GO

SELECT '574 rollback' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.risk_methodology_matrix_cell','U') IS NULL
             AND OBJECT_ID('grac_practice.fn_risk_scale_reassessment') IS NULL
             AND COL_LENGTH('grac_practice.risk_methodology_version','scale_changed') IS NULL
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_risk_methodology_publish')) NOT LIKE '%scale_changed%'
            THEN 'PASS' ELSE 'FAIL' END AS Result_;
GO
