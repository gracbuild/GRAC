-- =====================================================================
-- 118 Evidence Config -- hybrid role+employee Owner.
--
-- Prior state (from 079 + 082): evidence_config.evidence_owner is a
-- single free-text NVARCHAR(240) -- users typed a name or a role in
-- there. That does not survive employee turnover and cannot drive
-- notifications.
--
-- This migration:
--   1. ADDs four columns:
--        owner_role_id / owner_role_name
--        owner_employee_id / owner_display_name
--      Keeps evidence_owner intact for backward compatibility with
--      already-saved rows.
--   2. Rewrites sp_org_assurance_evidence_config_get to return the
--      four new columns.
--   3. Rewrites sp_org_assurance_evidence_config_save to accept the
--      four new fields via items_json + auto-resolve missing sides
--      (role given without employee -> pick first active holder;
--      employee given without role -> pull employee's current role).
--   4. Backfills evidence_owner as a display-only fallback when
--      neither role nor employee is populated (so old UIs still see
--      something meaningful).
--
-- Depends on 115 (role columns pattern), 117 (holder helpers).
--
-- Rollback: 118_evidence_config_role_ownership_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.org_assurance_evidence_config','U') IS NULL
   OR COL_LENGTH('grac_practice.org_assurance_evidence_config','evidence_owner') IS NULL
   OR OBJECT_ID('grac_practice.sp_org_role_primary_holder_pick','P') IS NULL
BEGIN
    RAISERROR('118: prerequisites missing -- run 082 + 117 first.', 16, 1);
    SET NOEXEC ON;
END
GO

BEGIN TRAN;

-- =====================================================================
-- 1. Add columns (idempotent)
-- =====================================================================
IF COL_LENGTH('grac_practice.org_assurance_evidence_config','owner_role_id') IS NULL
    ALTER TABLE grac_practice.org_assurance_evidence_config
        ADD owner_role_id BIGINT NULL;
GO
IF COL_LENGTH('grac_practice.org_assurance_evidence_config','owner_role_name') IS NULL
    ALTER TABLE grac_practice.org_assurance_evidence_config
        ADD owner_role_name NVARCHAR(120) NULL;
GO
IF COL_LENGTH('grac_practice.org_assurance_evidence_config','owner_employee_id') IS NULL
    ALTER TABLE grac_practice.org_assurance_evidence_config
        ADD owner_employee_id BIGINT NULL;
GO
IF COL_LENGTH('grac_practice.org_assurance_evidence_config','owner_display_name') IS NULL
    ALTER TABLE grac_practice.org_assurance_evidence_config
        ADD owner_display_name NVARCHAR(240) NULL;
GO

COMMIT TRAN;
GO

-- =====================================================================
-- 2. sp_org_assurance_evidence_config_get -- extend output
-- =====================================================================
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
    IF @version_id IS NULL
        THROW 53611, 'Definition has no current version.', 1;

    -- Header
    SELECT @definition_id       AS DefinitionId,
           @version_id          AS VersionId,
           @current_version_id  AS CurrentVersionId,
           @current_status_code AS CurrentStatusCode,
           CAST(CASE WHEN @current_status_code = N'Draft'
                     AND @version_id = @current_version_id
                     THEN 1 ELSE 0 END AS BIT) AS IsEditable;

    -- Rows (extended with role+employee owner)
    SELECT ec.org_assurance_evidence_config_id AS EvidenceConfigId,
           ec.evidence_type_id                 AS EvidenceTypeId,
           ec.evidence_type_code               AS EvidenceTypeCode,
           ec.evidence_type_name               AS EvidenceTypeName,
           ec.collection_method_id             AS CollectionMethodId,
           ec.collection_method_code           AS CollectionMethodCode,
           ec.collection_method_name           AS CollectionMethodName,
           ec.collection_frequency_id          AS CollectionFrequencyId,
           ec.collection_frequency_code        AS CollectionFrequencyCode,
           ec.collection_frequency_name        AS CollectionFrequencyName,
           ec.evidence_owner                   AS EvidenceOwner,
           ec.owner_role_id                    AS OwnerRoleId,
           ec.owner_role_name                  AS OwnerRoleName,
           ec.owner_employee_id                AS OwnerEmployeeId,
           ec.owner_display_name               AS OwnerDisplayName,
           ec.retention_period                 AS RetentionPeriod,
           ec.evidence_location                AS EvidenceLocation,
           ec.evidence_locator                 AS EvidenceLocator,
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

-- =====================================================================
-- 3. sp_org_assurance_evidence_config_save -- accept the four new
--    fields on each item + auto-resolve missing sides.
--
--    NOTE: the save is a full-replace over items_json (INSERT-only
--    after DELETE). Auto-resolve is done row-by-row post-INSERT via
--    UPDATE JOINs (simpler than expressing it inside OPENJSON).
-- =====================================================================
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

    -- Ownership + Draft-only check (unchanged).
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
        THROW 53608, 'Evidence config can only be edited when the current version is Draft.', 1;

    DECLARE @active_record_status_id INT = (
        SELECT TOP 1 record_status_id
        FROM grac_practice.record_status_master
        WHERE status_code = 'ACTIVE' OR status_name = 'Active'
        ORDER BY record_status_id);
    IF @active_record_status_id IS NULL SET @active_record_status_id = 1;

    BEGIN TRAN;

    DELETE FROM grac_practice.org_assurance_evidence_config
     WHERE org_assurance_definition_version_id = @current_version_id
       AND organization_id = @organization_id;

    INSERT INTO grac_practice.org_assurance_evidence_config
        (org_assurance_definition_id, org_assurance_definition_version_id,
         organization_id,
         evidence_type_id, evidence_type_code, evidence_type_name,
         collection_method_id, collection_method_code, collection_method_name,
         collection_frequency_id, collection_frequency_code, collection_frequency_name,
         evidence_owner, retention_period,
         owner_role_id, owner_role_name, owner_employee_id, owner_display_name,
         evidence_location, evidence_locator,
         evidence_label, description,
         is_mandatory, validity_days, expiry_warning_days, display_order,
         is_active, record_status_id, entered_by, entered_dt)
    SELECT @definition_id,
           @current_version_id,
           @organization_id,
           x.evidenceTypeId, x.evidenceTypeCode, x.evidenceTypeName,
           x.collectionMethodId, x.collectionMethodCode, x.collectionMethodName,
           x.collectionFrequencyId, x.collectionFrequencyCode, x.collectionFrequencyName,
           x.evidenceOwner, x.retentionPeriod,
           x.ownerRoleId, x.ownerRoleName, x.ownerEmployeeId, x.ownerDisplayName,
           x.evidenceLocation, x.evidenceLocator,
           x.evidenceLabel, x.description,
           ISNULL(x.isMandatory, 0),
           x.validityDays, x.expiryWarningDays,
           ISNULL(x.displayOrder, 0),
           1, @active_record_status_id, @actor, SYSUTCDATETIME()
    FROM OPENJSON(@items_json)
    WITH (
        evidenceTypeId          INT           '$.evidenceTypeId',
        evidenceTypeCode        NVARCHAR(60)  '$.evidenceTypeCode',
        evidenceTypeName        NVARCHAR(200) '$.evidenceTypeName',
        collectionMethodId      INT           '$.collectionMethodId',
        collectionMethodCode    NVARCHAR(60)  '$.collectionMethodCode',
        collectionMethodName    NVARCHAR(200) '$.collectionMethodName',
        collectionFrequencyId   INT           '$.collectionFrequencyId',
        collectionFrequencyCode NVARCHAR(60)  '$.collectionFrequencyCode',
        collectionFrequencyName NVARCHAR(120) '$.collectionFrequencyName',
        evidenceOwner           NVARCHAR(240) '$.evidenceOwner',
        retentionPeriod         NVARCHAR(120) '$.retentionPeriod',
        ownerRoleId             BIGINT        '$.ownerRoleId',
        ownerRoleName           NVARCHAR(120) '$.ownerRoleName',
        ownerEmployeeId         BIGINT        '$.ownerEmployeeId',
        ownerDisplayName        NVARCHAR(240) '$.ownerDisplayName',
        evidenceLocation        NVARCHAR(500) '$.evidenceLocation',
        evidenceLocator         NVARCHAR(500) '$.evidenceLocator',
        evidenceLabel           NVARCHAR(240) '$.evidenceLabel',
        description             NVARCHAR(MAX) '$.description',
        isMandatory             BIT           '$.isMandatory',
        validityDays            INT           '$.validityDays',
        expiryWarningDays       INT           '$.expiryWarningDays',
        displayOrder            INT           '$.displayOrder'
    ) x
    WHERE x.evidenceLabel IS NOT NULL AND LEN(LTRIM(RTRIM(x.evidenceLabel))) > 0;

    -- --------------------------------------------------------------
    -- Post-INSERT auto-resolve pass -- fill in whichever side was NULL.
    -- --------------------------------------------------------------
    -- (a) role_id populated but role_name missing -> resolve name
    UPDATE ec
       SET ec.owner_role_name = r.role_name
    FROM grac_practice.org_assurance_evidence_config ec
    JOIN grac_practice.organization_role r ON r.role_id = ec.owner_role_id
    WHERE ec.org_assurance_definition_version_id = @current_version_id
      AND ec.organization_id = @organization_id
      AND ec.owner_role_id IS NOT NULL
      AND (ec.owner_role_name IS NULL OR LEN(LTRIM(RTRIM(ec.owner_role_name))) = 0)
      AND r.organization_id = @organization_id;

    -- (b) role_id populated but no employee -> pick primary holder
    ;WITH src AS (
        SELECT ec.org_assurance_evidence_config_id AS cfg_id,
               ec.owner_role_id                     AS role_id,
               (SELECT TOP 1 e.employee_id
                FROM grac_practice.organization_employee e
                WHERE e.organization_id = @organization_id
                  AND e.role_id         = ec.owner_role_id
                  AND e.status          = N'Active'
                ORDER BY e.employee_name, e.employee_id) AS picked_employee_id,
               (SELECT TOP 1 e.employee_name
                FROM grac_practice.organization_employee e
                WHERE e.organization_id = @organization_id
                  AND e.role_id         = ec.owner_role_id
                  AND e.status          = N'Active'
                ORDER BY e.employee_name, e.employee_id) AS picked_employee_name
        FROM grac_practice.org_assurance_evidence_config ec
        WHERE ec.org_assurance_definition_version_id = @current_version_id
          AND ec.organization_id = @organization_id
          AND ec.owner_role_id IS NOT NULL
          AND ec.owner_employee_id IS NULL
    )
    UPDATE ec
       SET ec.owner_employee_id   = src.picked_employee_id,
           ec.owner_display_name  = src.picked_employee_name
    FROM grac_practice.org_assurance_evidence_config ec
    JOIN src ON src.cfg_id = ec.org_assurance_evidence_config_id
    WHERE src.picked_employee_id IS NOT NULL;

    -- (c) employee_id populated but role missing -> pull role from employee
    UPDATE ec
       SET ec.owner_role_id   = e.role_id,
           ec.owner_role_name = r.role_name
    FROM grac_practice.org_assurance_evidence_config ec
    JOIN grac_practice.organization_employee e ON e.employee_id = ec.owner_employee_id
    LEFT JOIN grac_practice.organization_role r ON r.role_id = e.role_id
    WHERE ec.org_assurance_definition_version_id = @current_version_id
      AND ec.organization_id = @organization_id
      AND ec.owner_employee_id IS NOT NULL
      AND ec.owner_role_id IS NULL
      AND e.organization_id = @organization_id;

    -- (d) employee_id populated but display_name missing -> pull name
    UPDATE ec
       SET ec.owner_display_name = e.employee_name
    FROM grac_practice.org_assurance_evidence_config ec
    JOIN grac_practice.organization_employee e ON e.employee_id = ec.owner_employee_id
    WHERE ec.org_assurance_definition_version_id = @current_version_id
      AND ec.organization_id = @organization_id
      AND ec.owner_employee_id IS NOT NULL
      AND (ec.owner_display_name IS NULL OR LEN(LTRIM(RTRIM(ec.owner_display_name))) = 0);

    -- (e) evidence_owner (legacy display column) -> keep it populated
    --     from whichever side the user picked, so pre-existing readers
    --     that only know about evidence_owner still show a value.
    UPDATE grac_practice.org_assurance_evidence_config
       SET evidence_owner = COALESCE(
                NULLIF(evidence_owner, N''),
                owner_display_name,
                owner_role_name)
    WHERE org_assurance_definition_version_id = @current_version_id
      AND organization_id = @organization_id
      AND (evidence_owner IS NULL OR LEN(LTRIM(RTRIM(evidence_owner))) = 0)
      AND (owner_display_name IS NOT NULL OR owner_role_name IS NOT NULL);

    -- History log (unchanged).
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

PRINT '118 Evidence config Owner extended to Role+Employee hybrid.';
GO

SET NOEXEC OFF;
GO
