-- =====================================================================
-- 6. The mapping of a version (default: the current one)
--    Result 1: DefinitionId, VersionId, StatusCode, IsEditable
--    Result 2: MappingId, MappingType, RecordId, RecordCode, RecordName,
--              ManualKind, ManualReference, Note, DisplayOrder,
--              PracticeId (instances), IsAvailable
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_definition_mapping_get
    @organization_id BIGINT,
    @definition_id   BIGINT,
    @version_id      BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL OR @definition_id IS NULL
        THROW 53602, 'organization_id and definition_id are required.', 1;

    DECLARE @def_org BIGINT, @current_version_id BIGINT, @status_code NVARCHAR(60);
    SELECT @def_org = d.organization_id, @current_version_id = d.current_version_id, @status_code = s.status_code
      FROM grac_practice.org_assurance_definition d
      JOIN grac_practice.org_assurance_status_master s ON s.org_assurance_status_id = d.current_status_id
     WHERE d.org_assurance_definition_id = @definition_id AND d.is_active = 1;
    IF @def_org IS NULL THROW 53606, 'Definition not found.', 1;
    IF @def_org <> @organization_id THROW 53607, 'Definition belongs to a different organization.', 1;
    IF @version_id IS NULL SET @version_id = @current_version_id;
    IF @version_id IS NULL THROW 53611, 'Definition has no current version.', 1;

    SELECT @definition_id AS DefinitionId,
           @version_id    AS VersionId,
           @status_code   AS StatusCode,
           CAST(CASE WHEN @status_code = N'Draft' AND @version_id = @current_version_id
                     THEN 1 ELSE 0 END AS BIT) AS IsEditable;

    SELECT m.definition_mapping_id AS MappingId,
           m.mapping_type          AS MappingType,
           m.record_id             AS RecordId,
           m.record_code           AS RecordCode,
           m.record_name           AS RecordName,
           m.manual_kind           AS ManualKind,
           m.manual_reference      AS ManualReference,
           m.note                  AS Note,
           m.display_order         AS DisplayOrder,
           pi.practice_id          AS PracticeId,
           CAST(CASE m.mapping_type
                    WHEN N'MANUAL' THEN 1
                    WHEN N'CONTROL_STATEMENT' THEN
                        CASE WHEN EXISTS (SELECT 1 FROM grac_practice.fn_org_scope_statement(@organization_id) fs
                                           WHERE fs.StatementId = m.record_id) THEN 1 ELSE 0 END
                    WHEN N'PRACTICE' THEN
                        CASE WHEN EXISTS (SELECT 1 FROM grac_practice.practice p
                                           WHERE p.practice_id = m.record_id AND p.organization_id = @organization_id
                                             AND p.status = N'Active') THEN 1 ELSE 0 END
                    WHEN N'PRACTICE_INSTANCE' THEN
                        CASE WHEN pi.status = N'Active' THEN 1 ELSE 0 END
                    ELSE 0 END AS BIT) AS IsAvailable
      FROM grac_practice.org_assurance_definition_mapping m
      LEFT JOIN grac_practice.practice_instance pi
             ON m.mapping_type = N'PRACTICE_INSTANCE'
            AND pi.practice_instance_id = m.record_id
            AND pi.organization_id = @organization_id
     WHERE m.org_assurance_definition_version_id = @version_id
       AND m.organization_id = @organization_id
       AND m.is_active = 1
     ORDER BY m.mapping_type, m.display_order, m.record_code, m.record_name;
END
GO

-- =====================================================================
-- 7. Save the mapping of the current (Draft) version -- replaces it.
--    @items_json: [{ "mappingType": "PRACTICE", "recordId": 12, "note": "..." },
--                  { "mappingType": "MANUAL", "manualKind": "CONTROL",
--                    "reference": "ISO 27001 A.5.1", "name": "...", "note": "..." }]
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_definition_mapping_save
    @organization_id BIGINT,
    @definition_id   BIGINT,
    @items_json      NVARCHAR(MAX),
    @actor           NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @organization_id IS NULL OR @definition_id IS NULL
        THROW 53602, 'organization_id and definition_id are required.', 1;
    IF @items_json IS NULL OR ISJSON(@items_json) = 0
        THROW 53707, 'Mapping: invalid list.', 1;

    DECLARE @def_org BIGINT, @version_id BIGINT, @status_code NVARCHAR(60);
    SELECT @def_org = d.organization_id, @version_id = d.current_version_id, @status_code = s.status_code
      FROM grac_practice.org_assurance_definition d
      JOIN grac_practice.org_assurance_status_master s ON s.org_assurance_status_id = d.current_status_id
     WHERE d.org_assurance_definition_id = @definition_id AND d.is_active = 1;
    IF @def_org IS NULL THROW 53606, 'Definition not found.', 1;
    IF @def_org <> @organization_id THROW 53607, 'Definition belongs to a different organization.', 1;
    IF @version_id IS NULL THROW 53611, 'Definition has no current version.', 1;
    IF @status_code <> N'Draft'
        THROW 53608, 'The mapping can only be edited when the current version is Draft.', 1;

    DECLARE @in TABLE (seq INT IDENTITY(1,1), mapping_type NVARCHAR(30), record_id BIGINT NULL,
                       manual_kind NVARCHAR(30) NULL, manual_reference NVARCHAR(120) NULL,
                       record_name NVARCHAR(400) NULL, note NVARCHAR(1000) NULL);
    INSERT @in (mapping_type, record_id, manual_kind, manual_reference, record_name, note)
    SELECT UPPER(LTRIM(RTRIM(x.mappingType))), x.recordId,
           NULLIF(UPPER(LTRIM(RTRIM(x.manualKind))), N''),
           LEFT(NULLIF(LTRIM(RTRIM(x.reference)), N''), 120),
           LEFT(NULLIF(LTRIM(RTRIM(x.name)), N''), 400),
           LEFT(NULLIF(LTRIM(RTRIM(x.note)), N''), 1000)
      FROM OPENJSON(@items_json)
           WITH (mappingType NVARCHAR(40)  '$.mappingType',
                 recordId    BIGINT        '$.recordId',
                 manualKind  NVARCHAR(40)  '$.manualKind',
                 reference   NVARCHAR(MAX) '$.reference',
                 name        NVARCHAR(MAX) '$.name',
                 note        NVARCHAR(MAX) '$.note') x;

    IF EXISTS (SELECT 1 FROM @in WHERE mapping_type IS NULL
                  OR mapping_type NOT IN (N'CONTROL_STATEMENT', N'PRACTICE', N'PRACTICE_INSTANCE', N'MANUAL'))
        THROW 53707, 'Mapping: unknown mapping type.', 1;
    IF EXISTS (SELECT 1 FROM @in WHERE mapping_type = N'MANUAL'
                  AND ISNULL(manual_kind, N'OTHER') NOT IN (N'CONTROL', N'PRACTICE', N'PRACTICE_INSTANCE', N'OTHER'))
        THROW 53707, 'Mapping: unknown manual mapping kind.', 1;
    IF EXISTS (SELECT 1 FROM @in WHERE mapping_type = N'MANUAL' AND record_name IS NULL)
        THROW 53709, 'Every manual mapping needs a name.', 1;
    IF EXISTS (SELECT 1 FROM @in WHERE mapping_type <> N'MANUAL' AND record_id IS NULL)
        THROW 53708, 'A mapped record is missing its id.', 1;

    -- The GRAC records: names from GRAC. A record already mapped on this
    -- version keeps its saved name when it is no longer active.
    DECLARE @rec TABLE (seq INT PRIMARY KEY, record_code NVARCHAR(120) NULL, record_name NVARCHAR(400) NULL);
    INSERT @rec (seq, record_code, record_name)
    SELECT i.seq,
           COALESCE(fs.StatementCode, p.practice_code, pi.instance_code, old.record_code),
           LEFT(COALESCE(fs.StatementName, p.practice_name, pi.instance_name, old.record_name), 400)
      FROM @in i
      LEFT JOIN grac_practice.fn_org_scope_statement(@organization_id) fs
             ON i.mapping_type = N'CONTROL_STATEMENT' AND fs.StatementId = i.record_id
      LEFT JOIN grac_practice.practice p
             ON i.mapping_type = N'PRACTICE' AND p.practice_id = i.record_id
            AND p.organization_id = @organization_id AND p.status = N'Active'
      LEFT JOIN grac_practice.practice_instance pi
             ON i.mapping_type = N'PRACTICE_INSTANCE' AND pi.practice_instance_id = i.record_id
            AND pi.organization_id = @organization_id AND pi.status = N'Active'
      OUTER APPLY (SELECT TOP 1 m.record_code, m.record_name
                     FROM grac_practice.org_assurance_definition_mapping m
                    WHERE m.org_assurance_definition_version_id = @version_id
                      AND m.is_active = 1
                      AND m.mapping_type = i.mapping_type
                      AND m.record_id = i.record_id) old
     WHERE i.mapping_type <> N'MANUAL'
       AND (fs.StatementId IS NOT NULL OR p.practice_id IS NOT NULL
            OR pi.practice_instance_id IS NOT NULL OR old.record_name IS NOT NULL);

    IF EXISTS (SELECT 1 FROM @in i WHERE i.mapping_type <> N'MANUAL'
                  AND NOT EXISTS (SELECT 1 FROM @rec r WHERE r.seq = i.seq))
        THROW 53708, 'A mapped record was not found in this organization. Reload the step and try again.', 1;

    BEGIN TRAN;

    UPDATE grac_practice.org_assurance_definition_mapping
       SET is_active = 0, updated_by = @actor, updated_dt = SYSUTCDATETIME()
     WHERE org_assurance_definition_version_id = @version_id
       AND organization_id = @organization_id
       AND is_active = 1;

    -- One row per GRAC record (a repeat is dropped), every manual row.
    INSERT grac_practice.org_assurance_definition_mapping
        (org_assurance_definition_version_id, organization_id, mapping_type, record_id,
         record_code, record_name, manual_kind, manual_reference, note,
         display_order, is_active, entered_by, entered_dt)
    SELECT @version_id, @organization_id, i.mapping_type, i.record_id,
           r.record_code, r.record_name, NULL, NULL, i.note,
           ROW_NUMBER() OVER (PARTITION BY i.mapping_type ORDER BY i.seq), 1, @actor, SYSUTCDATETIME()
      FROM @in i
      JOIN @rec r ON r.seq = i.seq
     WHERE i.mapping_type <> N'MANUAL'
       AND i.seq = (SELECT MIN(i2.seq) FROM @in i2
                     WHERE i2.mapping_type = i.mapping_type AND i2.record_id = i.record_id)
    UNION ALL
    SELECT @version_id, @organization_id, N'MANUAL', NULL,
           NULL, i.record_name, ISNULL(i.manual_kind, N'OTHER'), i.manual_reference, i.note,
           ROW_NUMBER() OVER (ORDER BY i.seq), 1, @actor, SYSUTCDATETIME()
      FROM @in i
     WHERE i.mapping_type = N'MANUAL';

    COMMIT;

    SELECT COUNT(*) AS MappingCount
      FROM grac_practice.org_assurance_definition_mapping
     WHERE org_assurance_definition_version_id = @version_id
       AND organization_id = @organization_id
       AND is_active = 1;
END
GO

-- =====================================================================
-- Verification
-- =====================================================================
SELECT '564 table' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.org_assurance_definition_mapping','U') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result_
UNION ALL SELECT '564 mapping step / gate / copy',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.fn_org_assurance_setup_steps')) LIKE '%mapping%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_org_assurance_definition_submit')) LIKE '%IsConfiguration%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_org_assurance_definition_version_copy_config')) LIKE '%org_assurance_definition_mapping%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT '564 procedures',
       CASE WHEN OBJECT_ID('grac_practice.sp_org_assurance_mapping_options','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_org_assurance_definition_mapping_get','P') IS NOT NULL
             AND OBJECT_ID('grac_practice.sp_org_assurance_definition_mapping_save','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END;
PRINT '564 complete. Restart the Api and publish Web.';
GO
SET NOEXEC OFF;
GO
