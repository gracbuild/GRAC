-- =====================================================================
-- 082 Rollback -- revert procs first (so they no longer reference the
-- new columns), then drop the new columns and helper proc.
-- =====================================================================
SET NOCOUNT ON;
GO

-- 1. Revert procs to their 080 shape (no new fields).
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_evidence_config_get
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

    SELECT @definition_id       AS DefinitionId,
           @version_id          AS VersionId,
           @current_version_id  AS CurrentVersionId,
           @current_status_code AS CurrentStatusCode,
           CAST(CASE WHEN @current_status_code = N'Draft'
                     AND @version_id = @current_version_id
                     THEN 1 ELSE 0 END AS BIT) AS IsEditable;

    SELECT ec.org_assurance_evidence_config_id AS EvidenceConfigId,
           ec.evidence_type_id                 AS EvidenceTypeId,
           ec.evidence_type_code               AS EvidenceTypeCode,
           ec.evidence_type_name               AS EvidenceTypeName,
           ec.collection_method_id             AS CollectionMethodId,
           ec.collection_method_code           AS CollectionMethodCode,
           ec.collection_method_name           AS CollectionMethodName,
           ec.evidence_label                   AS EvidenceLabel,
           ec.description                      AS Description,
           ec.is_mandatory                     AS IsMandatory,
           ec.validity_days                    AS ValidityDays,
           ec.expiry_warning_days              AS ExpiryWarningDays,
           ec.display_order                    AS DisplayOrder
    FROM grac_practice.org_assurance_evidence_config ec
    WHERE ec.organization_id = @organization_id
      AND ec.org_assurance_definition_version_id = @version_id
      AND ec.is_active = 1
    ORDER BY ec.display_order, ec.org_assurance_evidence_config_id;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_evidence_config_save
    @organization_id BIGINT,
    @definition_id   BIGINT,
    @items_json      NVARCHAR(MAX),
    @actor           NVARCHAR(100) = 'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @organization_id IS NULL OR @definition_id IS NULL
        THROW 53602, 'organization_id and definition_id are required.', 1;
    IF @items_json IS NULL SET @items_json = N'[]';
    IF ISJSON(@items_json) = 0
        THROW 53703, 'items_json is not a valid JSON document.', 1;

    DECLARE @def_org BIGINT, @current_version_id BIGINT, @current_status_code NVARCHAR(60);
    SELECT @def_org = d.organization_id, @current_version_id = d.current_version_id,
           @current_status_code = s.status_code
    FROM grac_practice.org_assurance_definition d
    JOIN grac_practice.org_assurance_status_master s ON s.org_assurance_status_id = d.current_status_id
    WHERE d.org_assurance_definition_id = @definition_id AND d.is_active = 1;

    IF @def_org IS NULL      THROW 53606, 'Definition not found.', 1;
    IF @def_org <> @organization_id THROW 53607, 'Definition belongs to a different organization.', 1;
    IF @current_version_id IS NULL   THROW 53611, 'Definition has no current version.', 1;
    IF @current_status_code <> N'Draft'
        THROW 53608, 'Evidence config can only be edited when the current version is Draft.', 1;

    DECLARE @active_record_status_id INT = (
        SELECT TOP 1 record_status_id FROM grac_practice.record_status_master
        WHERE status_code = 'ACTIVE' OR status_name = 'Active' ORDER BY record_status_id);
    IF @active_record_status_id IS NULL SET @active_record_status_id = 1;

    BEGIN TRAN;

    DELETE FROM grac_practice.org_assurance_evidence_config
     WHERE org_assurance_definition_version_id = @current_version_id
       AND organization_id = @organization_id;

    INSERT INTO grac_practice.org_assurance_evidence_config
        (org_assurance_definition_id, org_assurance_definition_version_id, organization_id,
         evidence_type_id, evidence_type_code, evidence_type_name,
         collection_method_id, collection_method_code, collection_method_name,
         evidence_label, description,
         is_mandatory, validity_days, expiry_warning_days, display_order,
         is_active, record_status_id, entered_by, entered_dt)
    SELECT @definition_id, @current_version_id, @organization_id,
           x.evidenceTypeId, x.evidenceTypeCode, x.evidenceTypeName,
           x.collectionMethodId, x.collectionMethodCode, x.collectionMethodName,
           x.evidenceLabel, x.description,
           ISNULL(x.isMandatory, 0),
           x.validityDays, x.expiryWarningDays,
           ISNULL(x.displayOrder, 0),
           1, @active_record_status_id, @actor, SYSUTCDATETIME()
    FROM OPENJSON(@items_json)
    WITH (
        evidenceTypeId       INT           '$.evidenceTypeId',
        evidenceTypeCode     NVARCHAR(60)  '$.evidenceTypeCode',
        evidenceTypeName     NVARCHAR(200) '$.evidenceTypeName',
        collectionMethodId   INT           '$.collectionMethodId',
        collectionMethodCode NVARCHAR(60)  '$.collectionMethodCode',
        collectionMethodName NVARCHAR(200) '$.collectionMethodName',
        evidenceLabel        NVARCHAR(240) '$.evidenceLabel',
        description          NVARCHAR(MAX) '$.description',
        isMandatory          BIT           '$.isMandatory',
        validityDays         INT           '$.validityDays',
        expiryWarningDays    INT           '$.expiryWarningDays',
        displayOrder         INT           '$.displayOrder'
    ) x
    WHERE x.evidenceLabel IS NOT NULL AND LEN(LTRIM(RTRIM(x.evidenceLabel))) > 0;

    DECLARE @current_status_id INT = (
        SELECT current_status_id FROM grac_practice.org_assurance_definition
        WHERE org_assurance_definition_id = @definition_id);

    INSERT INTO grac_practice.org_assurance_definition_history
        (org_assurance_definition_id, org_assurance_definition_version_id,
         organization_id, action_code, from_status_id, to_status_id,
         reason_text, actor_display_name, entered_by)
    VALUES
        (@definition_id, @current_version_id, @organization_id,
         N'EVIDENCE_EDIT', @current_status_id, @current_status_id,
         N'Evidence config saved', @actor, @actor);

    UPDATE grac_practice.org_assurance_definition
    SET updated_by = @actor, updated_dt = SYSUTCDATETIME()
    WHERE org_assurance_definition_id = @definition_id;

    COMMIT;
END
GO

-- 2. Drop the new frequency proc.
IF OBJECT_ID('grac_practice.sp_org_assurance_frequency_list','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_org_assurance_frequency_list;
GO

-- 3. Drop new columns (safe -- procs no longer reference them).
IF COL_LENGTH('grac_practice.org_assurance_evidence_config','evidence_locator') IS NOT NULL
    ALTER TABLE grac_practice.org_assurance_evidence_config DROP COLUMN evidence_locator;
GO
IF COL_LENGTH('grac_practice.org_assurance_evidence_config','evidence_location') IS NOT NULL
    ALTER TABLE grac_practice.org_assurance_evidence_config DROP COLUMN evidence_location;
GO
IF COL_LENGTH('grac_practice.org_assurance_evidence_config','retention_period') IS NOT NULL
    ALTER TABLE grac_practice.org_assurance_evidence_config DROP COLUMN retention_period;
GO
IF COL_LENGTH('grac_practice.org_assurance_evidence_config','evidence_owner') IS NOT NULL
    ALTER TABLE grac_practice.org_assurance_evidence_config DROP COLUMN evidence_owner;
GO
IF COL_LENGTH('grac_practice.org_assurance_evidence_config','collection_frequency_name') IS NOT NULL
    ALTER TABLE grac_practice.org_assurance_evidence_config DROP COLUMN collection_frequency_name;
GO
IF COL_LENGTH('grac_practice.org_assurance_evidence_config','collection_frequency_code') IS NOT NULL
    ALTER TABLE grac_practice.org_assurance_evidence_config DROP COLUMN collection_frequency_code;
GO
IF COL_LENGTH('grac_practice.org_assurance_evidence_config','collection_frequency_id') IS NOT NULL
    ALTER TABLE grac_practice.org_assurance_evidence_config DROP COLUMN collection_frequency_id;
GO

PRINT '082 rollback complete.';
GO
