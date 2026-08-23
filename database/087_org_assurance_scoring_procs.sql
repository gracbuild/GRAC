-- =====================================================================
-- 087 Organization Assurance Scoring Config -- Stage 2 procedures
--
-- Depends on 086 (schema).
--
-- Procedures:
--   sp_org_assurance_admin_scoring_model_list
--       Defensive discovery of grac_new.assurance_scoring_model
--       (same runtime column-name discovery as 072 / 077).
--
--   sp_org_assurance_scoring_model_type_list
--       Fixed set: PASS_FAIL / WEIGHTED / RISK_BASED / MATURITY_BASED /
--       PERCENTAGE / CUSTOM.
--
--   sp_org_assurance_scoring_get
--       Header + config + bands for a definition version (3 result sets).
--
--   sp_org_assurance_scoring_save
--       Draft-only full replacement. Header + bands JSON.
--
-- Rollback: 087_org_assurance_scoring_procs_rollback.sql.
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.org_assurance_scoring_config','U') IS NULL
   OR OBJECT_ID('grac_practice.org_assurance_scoring_band','U')  IS NULL
BEGIN
    RAISERROR('087: run 086 schema first.', 16, 1);
    RETURN;
END
GO

-- =====================================================================
-- sp_org_assurance_admin_scoring_model_list  (defensive discovery)
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_admin_scoring_model_list
AS
BEGIN
    SET NOCOUNT ON;

    IF OBJECT_ID('grac_new.assurance_scoring_model','U') IS NULL
    BEGIN
        SELECT CAST(NULL AS BIGINT)       AS Id,
               CAST(NULL AS NVARCHAR(120)) AS Code,
               CAST(NULL AS NVARCHAR(200)) AS Name,
               CAST(NULL AS NVARCHAR(1000)) AS Description
        WHERE 1 = 0;
        RETURN;
    END

    DECLARE @tbl_id INT = OBJECT_ID('grac_new.assurance_scoring_model');
    DECLARE @id_col NVARCHAR(128), @code_col NVARCHAR(128),
            @name_col NVARCHAR(128), @desc_col NVARCHAR(128),
            @status_col NVARCHAR(128);

    ;WITH candidates AS (SELECT c.name FROM sys.columns c WHERE c.object_id = @tbl_id)
    SELECT TOP 1 @id_col = name FROM candidates
    WHERE name IN (N'assurance_scoring_model_id', N'scoring_model_id', N'model_id', N'id')
    ORDER BY CASE name
        WHEN N'assurance_scoring_model_id' THEN 1
        WHEN N'scoring_model_id'           THEN 2
        WHEN N'model_id'                   THEN 3
        WHEN N'id'                         THEN 4
        ELSE 99 END;

    ;WITH candidates AS (SELECT c.name FROM sys.columns c WHERE c.object_id = @tbl_id)
    SELECT TOP 1 @code_col = name FROM candidates
    WHERE name IN (N'assurance_scoring_model_code', N'scoring_model_code',
                   N'model_code', N'code')
    ORDER BY CASE name
        WHEN N'assurance_scoring_model_code' THEN 1
        WHEN N'scoring_model_code'           THEN 2
        WHEN N'model_code'                   THEN 3
        WHEN N'code'                         THEN 4
        ELSE 99 END;

    ;WITH candidates AS (SELECT c.name FROM sys.columns c WHERE c.object_id = @tbl_id)
    SELECT TOP 1 @name_col = name FROM candidates
    WHERE name IN (N'assurance_scoring_model_name', N'scoring_model_name',
                   N'model_name', N'name', N'label', N'display_name')
    ORDER BY CASE name
        WHEN N'assurance_scoring_model_name' THEN 1
        WHEN N'scoring_model_name'           THEN 2
        WHEN N'model_name'                   THEN 3
        WHEN N'name'                         THEN 4
        WHEN N'label'                        THEN 5
        WHEN N'display_name'                 THEN 6
        ELSE 99 END;

    ;WITH candidates AS (SELECT c.name FROM sys.columns c WHERE c.object_id = @tbl_id)
    SELECT TOP 1 @desc_col = name FROM candidates
    WHERE name IN (N'description', N'notes', N'remarks');

    ;WITH candidates AS (SELECT c.name FROM sys.columns c WHERE c.object_id = @tbl_id)
    SELECT TOP 1 @status_col = name FROM candidates
    WHERE name IN (N'status', N'is_active', N'active_flag');

    IF @id_col IS NULL OR @name_col IS NULL
    BEGIN
        SELECT CAST(NULL AS BIGINT)       AS Id,
               CAST(NULL AS NVARCHAR(120)) AS Code,
               CAST(NULL AS NVARCHAR(200)) AS Name,
               CAST(NULL AS NVARCHAR(1000)) AS Description
        WHERE 1 = 0;
        RETURN;
    END

    DECLARE @sql NVARCHAR(MAX) = N'
        SELECT ' + QUOTENAME(@id_col) + N' AS Id,
               ' + COALESCE(QUOTENAME(@code_col), N'CAST(NULL AS NVARCHAR(120))') + N' AS Code,
               ' + QUOTENAME(@name_col) + N' AS Name,
               ' + COALESCE(QUOTENAME(@desc_col), N'CAST(NULL AS NVARCHAR(1000))') + N' AS Description
        FROM grac_new.assurance_scoring_model';

    IF @status_col = N'status'
        SET @sql = @sql + N' WHERE ' + QUOTENAME(@status_col) + N' = N''Active''';
    ELSE IF @status_col IN (N'is_active', N'active_flag')
        SET @sql = @sql + N' WHERE ' + QUOTENAME(@status_col) + N' = 1';

    SET @sql = @sql + N' ORDER BY ' + QUOTENAME(@name_col) + N';';

    EXEC sp_executesql @sql;
END
GO

-- =====================================================================
-- sp_org_assurance_scoring_model_type_list  (fixed vocabulary)
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_scoring_model_type_list
AS
BEGIN
    SET NOCOUNT ON;
    SELECT ModelTypeCode, ModelTypeName, DisplayOrder,
           SupportsBands, SupportsThreshold
    FROM (VALUES
        (N'PASS_FAIL',      N'Pass / Fail',    1, CAST(0 AS BIT), CAST(1 AS BIT)),
        (N'WEIGHTED',       N'Weighted',       2, CAST(0 AS BIT), CAST(1 AS BIT)),
        (N'RISK_BASED',     N'Risk Based',     3, CAST(1 AS BIT), CAST(0 AS BIT)),
        (N'MATURITY_BASED', N'Maturity Based', 4, CAST(1 AS BIT), CAST(0 AS BIT)),
        (N'PERCENTAGE',     N'Percentage',     5, CAST(1 AS BIT), CAST(1 AS BIT)),
        (N'CUSTOM',         N'Custom',         6, CAST(1 AS BIT), CAST(1 AS BIT))
    ) t(ModelTypeCode, ModelTypeName, DisplayOrder, SupportsBands, SupportsThreshold)
    ORDER BY DisplayOrder;
END
GO

-- =====================================================================
-- sp_org_assurance_scoring_get
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_scoring_get
    @organization_id BIGINT,
    @definition_id   BIGINT,
    @version_id      BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL OR @definition_id IS NULL
        THROW 53602, 'organization_id and definition_id are required.', 1;

    DECLARE @def_org BIGINT, @current_version_id BIGINT, @current_status_code NVARCHAR(60);

    SELECT @def_org             = d.organization_id,
           @current_version_id  = d.current_version_id,
           @current_status_code = s.status_code
    FROM grac_practice.org_assurance_definition d
    JOIN grac_practice.org_assurance_status_master s
         ON s.org_assurance_status_id = d.current_status_id
    WHERE d.org_assurance_definition_id = @definition_id
      AND d.is_active = 1;

    IF @def_org IS NULL      THROW 53606, 'Definition not found.', 1;
    IF @def_org <> @organization_id
        THROW 53607, 'Definition belongs to a different organization.', 1;

    IF @version_id IS NULL SET @version_id = @current_version_id;

    -- 1) Header.
    SELECT @definition_id       AS DefinitionId,
           @version_id          AS VersionId,
           @current_version_id  AS CurrentVersionId,
           @current_status_code AS CurrentStatusCode,
           CAST(CASE WHEN @current_status_code = N'Draft'
                     AND @version_id = @current_version_id
                     THEN 1 ELSE 0 END AS BIT) AS IsEditable;

    -- 2) Scoring config row (0 or 1).
    SELECT sc.org_assurance_scoring_config_id AS ScoringConfigId,
           sc.scoring_model_id                AS ScoringModelId,
           sc.scoring_model_code              AS ScoringModelCode,
           sc.scoring_model_name              AS ScoringModelName,
           sc.scoring_model_type              AS ScoringModelType,
           sc.max_score                       AS MaxScore,
           sc.pass_threshold                  AS PassThreshold,
           sc.warning_threshold               AS WarningThreshold,
           sc.fail_threshold                  AS FailThreshold,
           sc.description                     AS Description
    FROM grac_practice.org_assurance_scoring_config sc
    WHERE sc.organization_id = @organization_id
      AND sc.org_assurance_definition_version_id = @version_id
      AND sc.is_active = 1;

    -- 3) Bands.
    SELECT sb.org_assurance_scoring_band_id AS BandId,
           sb.band_order                     AS BandOrder,
           sb.band_code                      AS BandCode,
           sb.band_name                      AS BandName,
           sb.min_score                      AS MinScore,
           sb.max_score                      AS MaxScore,
           sb.outcome_code                   AS OutcomeCode,
           sb.color_hex                      AS ColorHex,
           sb.description                    AS Description
    FROM grac_practice.org_assurance_scoring_band sb
    JOIN grac_practice.org_assurance_scoring_config sc
         ON sc.org_assurance_scoring_config_id = sb.org_assurance_scoring_config_id
    WHERE sc.organization_id = @organization_id
      AND sc.org_assurance_definition_version_id = @version_id
      AND sb.is_active = 1
    ORDER BY sb.band_order, sb.org_assurance_scoring_band_id;
END
GO

-- =====================================================================
-- sp_org_assurance_scoring_save
--   Full-replacement save. Draft-only. Wipes existing header + bands
--   for the current version and reinserts.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_scoring_save
    @organization_id BIGINT,
    @definition_id   BIGINT,
    @header_json     NVARCHAR(MAX),
    @bands_json      NVARCHAR(MAX),
    @actor           NVARCHAR(100) = 'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @organization_id IS NULL OR @definition_id IS NULL
        THROW 53602, 'organization_id and definition_id are required.', 1;
    IF @header_json IS NULL SET @header_json = N'{}';
    IF @bands_json  IS NULL SET @bands_json  = N'[]';
    IF ISJSON(@header_json) = 0 THROW 53703, 'header_json is not a valid JSON document.', 1;
    IF ISJSON(@bands_json)  = 0 THROW 53703, 'bands_json is not a valid JSON document.',  1;

    DECLARE @def_org BIGINT, @current_version_id BIGINT, @current_status_code NVARCHAR(60);

    SELECT @def_org             = d.organization_id,
           @current_version_id  = d.current_version_id,
           @current_status_code = s.status_code
    FROM grac_practice.org_assurance_definition d
    JOIN grac_practice.org_assurance_status_master s
         ON s.org_assurance_status_id = d.current_status_id
    WHERE d.org_assurance_definition_id = @definition_id
      AND d.is_active = 1;

    IF @def_org IS NULL      THROW 53606, 'Definition not found.', 1;
    IF @def_org <> @organization_id
        THROW 53607, 'Definition belongs to a different organization.', 1;
    IF @current_version_id IS NULL
        THROW 53611, 'Definition has no current version.', 1;
    IF @current_status_code <> N'Draft'
        THROW 53608, 'Scoring config can only be edited when the current version is Draft.', 1;

    DECLARE @active_record_status_id INT = (
        SELECT TOP 1 record_status_id
        FROM grac_practice.record_status_master
        WHERE status_code = 'ACTIVE' OR status_name = 'Active'
        ORDER BY record_status_id);
    IF @active_record_status_id IS NULL SET @active_record_status_id = 1;

    -- Header extraction.
    DECLARE @scoring_model_id     BIGINT       = TRY_CAST(JSON_VALUE(@header_json, '$.scoringModelId')      AS BIGINT),
            @scoring_model_code   NVARCHAR(120) = JSON_VALUE(@header_json, '$.scoringModelCode'),
            @scoring_model_name   NVARCHAR(200) = JSON_VALUE(@header_json, '$.scoringModelName'),
            @scoring_model_type   NVARCHAR(30)  = ISNULL(NULLIF(JSON_VALUE(@header_json, '$.scoringModelType'), N''), N'PASS_FAIL'),
            @max_score            DECIMAL(10,2) = TRY_CAST(JSON_VALUE(@header_json, '$.maxScore')           AS DECIMAL(10,2)),
            @pass_threshold       DECIMAL(10,2) = TRY_CAST(JSON_VALUE(@header_json, '$.passThreshold')      AS DECIMAL(10,2)),
            @warning_threshold    DECIMAL(10,2) = TRY_CAST(JSON_VALUE(@header_json, '$.warningThreshold')   AS DECIMAL(10,2)),
            @fail_threshold       DECIMAL(10,2) = TRY_CAST(JSON_VALUE(@header_json, '$.failThreshold')      AS DECIMAL(10,2)),
            @description          NVARCHAR(MAX) = JSON_VALUE(@header_json, '$.description');

    IF @scoring_model_type NOT IN (N'PASS_FAIL', N'WEIGHTED', N'RISK_BASED',
                                    N'MATURITY_BASED', N'PERCENTAGE', N'CUSTOM')
        SET @scoring_model_type = N'PASS_FAIL';

    BEGIN TRAN;

    DELETE sb
      FROM grac_practice.org_assurance_scoring_band sb
      JOIN grac_practice.org_assurance_scoring_config sc
           ON sc.org_assurance_scoring_config_id = sb.org_assurance_scoring_config_id
     WHERE sc.org_assurance_definition_version_id = @current_version_id
       AND sc.organization_id = @organization_id;

    DELETE FROM grac_practice.org_assurance_scoring_config
     WHERE org_assurance_definition_version_id = @current_version_id
       AND organization_id = @organization_id;

    INSERT INTO grac_practice.org_assurance_scoring_config
        (org_assurance_definition_id, org_assurance_definition_version_id, organization_id,
         scoring_model_id, scoring_model_code, scoring_model_name,
         scoring_model_type,
         max_score, pass_threshold, warning_threshold, fail_threshold,
         description,
         is_active, record_status_id, entered_by, entered_dt)
    VALUES
        (@definition_id, @current_version_id, @organization_id,
         @scoring_model_id, @scoring_model_code, @scoring_model_name,
         @scoring_model_type,
         @max_score, @pass_threshold, @warning_threshold, @fail_threshold,
         @description,
         1, @active_record_status_id, @actor, SYSUTCDATETIME());

    DECLARE @config_id BIGINT = SCOPE_IDENTITY();

    INSERT INTO grac_practice.org_assurance_scoring_band
        (org_assurance_scoring_config_id, org_assurance_definition_version_id, organization_id,
         band_order, band_code, band_name, min_score, max_score, outcome_code, color_hex, description,
         is_active, entered_by, entered_dt)
    SELECT @config_id, @current_version_id, @organization_id,
           x.bandOrder,
           x.bandCode, x.bandName, x.minScore, x.maxScore,
           CASE WHEN x.outcomeCode IN (N'PASS', N'WARNING', N'FAIL') THEN x.outcomeCode ELSE NULL END,
           x.colorHex, x.description,
           1, @actor, SYSUTCDATETIME()
    FROM OPENJSON(@bands_json)
    WITH (
        bandOrder    INT           '$.bandOrder',
        bandCode     NVARCHAR(60)  '$.bandCode',
        bandName     NVARCHAR(160) '$.bandName',
        minScore     DECIMAL(10,2) '$.minScore',
        maxScore     DECIMAL(10,2) '$.maxScore',
        outcomeCode  NVARCHAR(30)  '$.outcomeCode',
        colorHex     NVARCHAR(20)  '$.colorHex',
        description  NVARCHAR(MAX) '$.description'
    ) x
    WHERE x.bandName IS NOT NULL AND LEN(LTRIM(RTRIM(x.bandName))) > 0
      AND x.minScore IS NOT NULL AND x.maxScore IS NOT NULL
      AND x.maxScore >= x.minScore;

    -- History log.
    DECLARE @current_status_id INT = (
        SELECT current_status_id FROM grac_practice.org_assurance_definition
        WHERE org_assurance_definition_id = @definition_id);

    INSERT INTO grac_practice.org_assurance_definition_history
        (org_assurance_definition_id, org_assurance_definition_version_id,
         organization_id, action_code, from_status_id, to_status_id,
         reason_text, actor_display_name, entered_by)
    VALUES
        (@definition_id, @current_version_id, @organization_id,
         N'SCORING_EDIT', @current_status_id, @current_status_id,
         N'Scoring config saved', @actor, @actor);

    UPDATE grac_practice.org_assurance_definition
    SET updated_by = @actor, updated_dt = SYSUTCDATETIME()
    WHERE org_assurance_definition_id = @definition_id;

    COMMIT;
END
GO

PRINT '087 Organization Assurance Scoring procedures deployed.';
GO
