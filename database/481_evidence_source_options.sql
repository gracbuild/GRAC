-- =====================================================================
-- 481 Operationalize one-time evidence -- how the evidence is provided
--
-- Change request 2026-10-23 (sir):
--   * Operationalize shows only ONE-TIME evidence under an obligation.
--     Recurring evidence is attached to each scheduled task (473), so the
--     workspace no longer lists it (UI only -- the rows stay).
--   * Every one-time evidence row offers three options:
--       Direct Upload                 -> a file picker
--       Evidence Center Reference     -> "Select from Evidence Center"
--       External Evidence Reference   -> the Location and Locator boxes
--     and only the control of the chosen option is shown.
--
-- WHAT THIS SCRIPT DOES
--   1. practice_instance_evidence.evidence_source NVARCHAR(30) NULL,
--      CHECK DirectUpload | EvidenceCenter | External. NULL = not chosen.
--   2. Backfills existing rows (only where evidence_source IS NULL):
--        an active Evidence Center link     -> DirectUpload
--        otherwise location or locator set  -> External
--        otherwise                          -> stays NULL
--   3. grac_practice.fn_pm_instance_evidence_is_resolved -- the ONE place
--      the "resolved" rule lives now (agreed 2026-10-23):
--        External                       location AND locator
--        DirectUpload / EvidenceCenter  an active Evidence Center link
--        NULL (not chosen)              either of the above
--      Before 481 only location AND locator resolved a row (353), and an
--      attached file did not (473).
--   4. sp_resolve_evidence_list (476 body) -- IsResolved via the function,
--      new column EvidenceSource.
--   5. sp_resolve_evidence_save (473 body) -- new optional
--      @evidence_source (NULL = unchanged, validated: 52920); IsResolved /
--      ResolvedOnInstance via the function; new result column
--      EvidenceSource. A row with an active link is no longer reset to
--      "Inherited" when its text boxes are blank.
--
-- WHAT IS DELIBERATELY NOT CHANGED
--   * Location / locator / links are never deleted when the option is
--     switched. Only the chosen option counts towards resolved, so
--     switching back brings the earlier answer back.
--   * sp_resolve_obligation_list's ResolvedEvidenceCount keeps the 353
--     rule. Its only reader was the Operationalize card head, which now
--     counts from sp_resolve_evidence_list (one-time rows only).
--   * Evidence Center procedures, links, task evidence (477): unchanged.
--
-- DEPENDS ON: 140 (practice_instance_evidence), 254 (evidence_name),
--             473 (cadence, sp_resolve_evidence_save body),
--             476 (evidence_link, sp_resolve_evidence_list body).
-- Rollback:   481_evidence_source_options_rollback.sql
-- Idempotent. ASCII-only (sqlcmd codepage safety).
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

-- ---------------------------------------------------------------------
-- 0. Prerequisites -- every column the re-issued bodies read.
-- ---------------------------------------------------------------------
DECLARE @ok BIT = 1;
IF OBJECT_ID('grac_practice.practice_instance_evidence','U') IS NULL
BEGIN PRINT 'ABORT (481): practice_instance_evidence missing -- run 140 first.'; SET @ok = 0; END
IF COL_LENGTH('grac_practice.practice_instance_evidence','evidence_name') IS NULL
BEGIN PRINT 'ABORT (481): practice_instance_evidence.evidence_name missing -- run 254 first.'; SET @ok = 0; END
IF COL_LENGTH('grac_practice.practice_instance_evidence','source_practice_instance_obligation_id') IS NULL
BEGIN PRINT 'ABORT (481): source_practice_instance_obligation_id missing -- run 231/232 first.'; SET @ok = 0; END
IF COL_LENGTH('grac_practice.practice_instance_evidence','source_obligation_evidence_id') IS NULL
BEGIN PRINT 'ABORT (481): source_obligation_evidence_id missing -- run 306 first.'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.vw_pm_instance_evidence_cadence','V') IS NULL
BEGIN PRINT 'ABORT (481): vw_pm_instance_evidence_cadence missing -- run 473/475 first.'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.evidence_link','U') IS NULL
   OR COL_LENGTH('grac_practice.evidence_link','target_type') IS NULL
   OR COL_LENGTH('grac_practice.evidence_link','target_id') IS NULL
BEGIN PRINT 'ABORT (481): evidence_link missing -- run 476 first.'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.fn_org_requirement_obligation_evidence') IS NULL
BEGIN PRINT 'ABORT (481): fn_org_requirement_obligation_evidence missing -- run 394 first.'; SET @ok = 0; END
IF OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_resolve_evidence_save')) NOT LIKE '%@clear_evidence_description%'
BEGIN PRINT 'ABORT (481): sp_resolve_evidence_save is older than 473 -- run 473 first.'; SET @ok = 0; END
IF @ok = 0
BEGIN
    RAISERROR('481_evidence_source_options: prerequisites failed -- see the messages above.', 16, 1);
    SET NOEXEC ON;
END
GO

-- ---------------------------------------------------------------------
-- 1. Column + check
-- ---------------------------------------------------------------------
IF COL_LENGTH('grac_practice.practice_instance_evidence','evidence_source') IS NULL
BEGIN
    ALTER TABLE grac_practice.practice_instance_evidence
        ADD evidence_source NVARCHAR(30) NULL;
    PRINT '481: practice_instance_evidence.evidence_source added.';
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints
               WHERE name = 'ck_pm_instance_evidence_source'
                 AND parent_object_id = OBJECT_ID('grac_practice.practice_instance_evidence'))
BEGIN
    ALTER TABLE grac_practice.practice_instance_evidence
        ADD CONSTRAINT ck_pm_instance_evidence_source
        CHECK (evidence_source IS NULL
               OR evidence_source IN (N'DirectUpload', N'EvidenceCenter', N'External'));
    PRINT '481: ck_pm_instance_evidence_source added.';
END
GO

-- ---------------------------------------------------------------------
-- 2. Backfill (only rows not chosen yet, so a re-run changes nothing)
-- ---------------------------------------------------------------------
UPDATE e
   SET evidence_source = CASE
           WHEN EXISTS (SELECT 1 FROM grac_practice.evidence_link l
                         WHERE l.target_type = N'InstanceEvidence'
                           AND l.target_id   = e.evidence_id
                           AND l.status      = N'Active')
                THEN N'DirectUpload'
           ELSE N'External' END
FROM   grac_practice.practice_instance_evidence e
WHERE  e.evidence_source IS NULL
  AND (EXISTS (SELECT 1 FROM grac_practice.evidence_link l
                WHERE l.target_type = N'InstanceEvidence'
                  AND l.target_id   = e.evidence_id
                  AND l.status      = N'Active')
       OR NULLIF(LTRIM(RTRIM(ISNULL(e.evidence_location, N''))), N'') IS NOT NULL
       OR NULLIF(LTRIM(RTRIM(ISNULL(e.evidence_locator,  N''))), N'') IS NOT NULL);
PRINT '481: evidence_source backfilled on ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + ' row(s).';
GO

-- ---------------------------------------------------------------------
-- 3. The resolved rule, in one place
-- ---------------------------------------------------------------------
CREATE OR ALTER FUNCTION grac_practice.fn_pm_instance_evidence_is_resolved
(
    @evidence_source   NVARCHAR(30),
    @evidence_location NVARCHAR(500),
    @evidence_locator  NVARCHAR(500),
    @evidence_id       BIGINT
)
RETURNS BIT
AS
BEGIN
    DECLARE @has_reference BIT =
        CASE WHEN NULLIF(LTRIM(RTRIM(ISNULL(@evidence_location, N''))), N'') IS NOT NULL
              AND NULLIF(LTRIM(RTRIM(ISNULL(@evidence_locator,  N''))), N'') IS NOT NULL
             THEN 1 ELSE 0 END;
    DECLARE @has_link BIT =
        CASE WHEN EXISTS (SELECT 1 FROM grac_practice.evidence_link l
                           WHERE l.target_type = N'InstanceEvidence'
                             AND l.target_id   = @evidence_id
                             AND l.status      = N'Active')
             THEN 1 ELSE 0 END;

    RETURN CASE
        WHEN @evidence_source = N'External'                            THEN @has_reference
        WHEN @evidence_source IN (N'DirectUpload', N'EvidenceCenter')  THEN @has_link
        WHEN @has_reference = 1 OR @has_link = 1                       THEN CAST(1 AS BIT)
        ELSE CAST(0 AS BIT) END;
END
GO

-- =====================================================================
-- 4. sp_resolve_evidence_list (476 body; IsResolved per source, + EvidenceSource)
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_resolve_evidence_list
    @practice_instance_id BIGINT,
    @obligation_id        BIGINT = NULL,
    -- 232. Filters to one organisation-defined obligation. Separate from
    -- @obligation_id rather than overloading it: they index different
    -- tables, and a NULL @obligation_id already means "every row".
    @practice_instance_obligation_id BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @practice_instance_id IS NULL
        THROW 52640, 'sp_resolve_evidence_list: practice_instance_id is required.', 1;

    -- 394: repository evidence text comes from the organization's copy.
    DECLARE @copy_organization_id BIGINT = (
        SELECT organization_id FROM grac_practice.practice_instance
        WHERE practice_instance_id = @practice_instance_id);

    SELECT
        e.evidence_id             AS EvidenceId,
        e.source_obligation_id    AS SourceObligationId,
        -- 231/232. A locally added obligation has no GRAC_New id, so this
        -- is what says which one an evidence row belongs to.
        e.source_practice_instance_obligation_id AS SourcePracticeInstanceObligationId,
        -- Migration 254: the organisation's own label for this row.
        e.evidence_name           AS EvidenceName,
        e.evidence_type_id        AS EvidenceTypeId,
        et.evidence_type_name     AS EvidenceType,

        -- Migration 306: what the authority published as the instruction
        -- for this evidence. Exact source row first, then the
        -- obligation + type fallback for a row that has no
        -- source_obligation_evidence_id.
        -- CAST before LTRIM/RTRIM: the column is repository-owned, and
        -- LTRIM on an ntext argument is Msg 8116, not a NULL. Casting
        -- costs nothing when it is already NVARCHAR(MAX) and removes the
        -- guess about which it is.
        COALESCE(
            (SELECT TOP 1 NULLIF(LTRIM(RTRIM(CAST(roe.remarks AS NVARCHAR(MAX)))), N'')
             FROM   grac_practice.fn_org_requirement_obligation_evidence(@copy_organization_id) roe
             WHERE  roe.obligation_evidence_id = e.source_obligation_evidence_id
               AND  roe.status = N'Active'),
            (SELECT TOP 1 NULLIF(LTRIM(RTRIM(CAST(roe2.remarks AS NVARCHAR(MAX)))), N'')
             FROM   grac_practice.vw_pm_obligation_evidence oe
             JOIN   grac_practice.fn_org_requirement_obligation_evidence(@copy_organization_id) roe2
                    ON roe2.obligation_evidence_id = oe.obligation_evidence_id
             JOIN   GRAC_New.evidence_type_master get
                    ON get.evidence_type_id = oe.evidence_type_id
             JOIN   grac_practice.evidence_type_master pet
                    ON pet.evidence_type_name = get.evidence_type_name
                   AND pet.is_active = 1
             WHERE  oe.organization_id    = @copy_organization_id
               AND  oe.obligation_id      = e.source_obligation_id
               AND  pet.evidence_type_id  = e.evidence_type_id
               AND  roe2.status = N'Active'
               AND  NULLIF(LTRIM(RTRIM(CAST(roe2.remarks AS NVARCHAR(MAX)))), N'') IS NOT NULL
             ORDER  BY oe.obligation_evidence_id)
        )                         AS EvidenceRemarks,

        e.is_mandatory            AS IsMandatory,
        e.collection_method_id    AS CollectionMethodId,
        cm.collection_method_name AS CollectionMethod,
        e.collection_frequency_id AS CollectionFrequencyId,
        f.frequency_name          AS CollectionFrequency,
        e.assurance_type_id       AS AssuranceTypeId,
        at2.assurance_type_name   AS AssuranceType,
        e.retention_period        AS RetentionPeriod,
        e.evidence_owner          AS EvidenceOwner,
        e.evidence_description    AS EvidenceDescription,
        e.evidence_location       AS EvidenceLocation,
        e.evidence_locator        AS EvidenceLocator,
        e.alignment_status_id     AS AlignmentStatusId,
        al.alignment_status_name  AS AlignmentStatus,
        e.inherited_from_repository AS InheritedFromRepository,
        e.organization_modified     AS OrganizationModified,

        -- 481: resolved per the evidence source the organisation chose
        -- (fn_pm_instance_evidence_is_resolved): External = location AND
        -- locator; Direct Upload / Evidence Center Reference = an active
        -- Evidence Center link; not chosen yet = either of those. The
        -- published remark and the name still never resolve a row.
        grac_practice.fn_pm_instance_evidence_is_resolved(
            e.evidence_source, e.evidence_location, e.evidence_locator, e.evidence_id) AS IsResolved,
        -- 481: DirectUpload | EvidenceCenter | External; NULL = not chosen.
        e.evidence_source         AS EvidenceSource,

        -- 473: is this proof produced once (attached here, at
        -- implementation) or again for every scheduled occurrence?
        -- Read from the organisation's copy of the published spec through
        -- vw_pm_instance_evidence_cadence; 'Default' = nothing published
        -- (organisation-defined evidence), which is treated as Recurring.
        cad.EvidenceCadence       AS EvidenceCadence,
        cad.EvidenceCadenceLabel  AS EvidenceCadenceLabel,
        cad.CadenceSource         AS EvidenceCadenceSource,
        -- 476: files are Evidence Center links now.
        (SELECT COUNT(*) FROM grac_practice.evidence_link ea
          WHERE ea.target_type = N'InstanceEvidence'
            AND ea.target_id = e.evidence_id AND ea.status = N'Active') AS AttachmentCount
    FROM   grac_practice.practice_instance_evidence e
    LEFT   JOIN grac_practice.vw_pm_instance_evidence_cadence cad
           ON cad.evidence_id = e.evidence_id
    LEFT   JOIN grac_practice.evidence_type_master et
           ON et.evidence_type_id = e.evidence_type_id
    LEFT   JOIN grac_practice.collection_method_master cm
           ON cm.collection_method_id = e.collection_method_id
    LEFT   JOIN grac_practice.frequency_master f
           ON f.frequency_id = e.collection_frequency_id
    LEFT   JOIN grac_practice.assurance_type_master at2
           ON at2.assurance_type_id = e.assurance_type_id
    LEFT   JOIN grac_practice.evidence_alignment_status_master al
           ON al.alignment_status_id = e.alignment_status_id
    WHERE  e.practice_instance_id = @practice_instance_id
      AND  e.status = N'Active'
      AND (@obligation_id IS NULL OR e.source_obligation_id = @obligation_id)
      AND (@practice_instance_obligation_id IS NULL
           OR e.source_practice_instance_obligation_id = @practice_instance_obligation_id)
    ORDER  BY CASE WHEN e.source_obligation_id IS NULL THEN 1 ELSE 0 END,
              e.source_obligation_id,
              -- Migration 254: a named row sorts by its name, an unnamed
              -- one keeps sorting by type, so adding a name never scatters
              -- the list into a new order the operator did not ask for.
              COALESCE(NULLIF(LTRIM(RTRIM(e.evidence_name)), N''), et.evidence_type_name);
END
GO


-- =====================================================================
-- 5. sp_resolve_evidence_save (473 body; + @evidence_source)
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_resolve_evidence_save
    @practice_instance_id   BIGINT,
    @evidence_id            BIGINT,
    @is_mandatory           BIT           = NULL,
    @collection_method_id   INT           = NULL,
    @collection_frequency_id INT          = NULL,
    @assurance_type_id      INT           = NULL,
    @retention_period       NVARCHAR(120) = NULL,
    @owner_employee_id      BIGINT        = NULL,
    @clear_owner            BIT           = 0,
    @evidence_description   NVARCHAR(MAX) = NULL,
    @evidence_location      NVARCHAR(500) = NULL,
    @evidence_locator       NVARCHAR(500) = NULL,
    -- Migration 254. NULL means "unchanged", same contract as every other
    -- optional field here.
    @evidence_name          NVARCHAR(300) = NULL,
    @actor                  NVARCHAR(100) = N'system',
    -- Migration 473. The Description box now opens on the published
    -- evidence description, so "back to what was published" has to be
    -- sayable: 1 stores NULL, and the screen shows the published text
    -- again. NULL @evidence_description alone still means "unchanged".
    @clear_evidence_description BIT       = 0,
    -- Migration 481. How the evidence is provided: DirectUpload,
    -- EvidenceCenter or External. NULL means "unchanged".
    @evidence_source        NVARCHAR(30)  = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @practice_instance_id IS NULL OR @evidence_id IS NULL
        THROW 52641, 'sp_resolve_evidence_save: practice instance and evidence row are both required.', 1;

    DECLARE @organization_id BIGINT;
    SELECT @organization_id = e.organization_id
    FROM   grac_practice.practice_instance_evidence e
    WHERE  e.evidence_id          = @evidence_id
      AND  e.practice_instance_id = @practice_instance_id
      AND  e.status = N'Active';

    -- Scoped to the instance the caller already opened, so an evidence id
    -- from somewhere else matches nothing rather than being editable by
    -- guessing the number.
    IF @organization_id IS NULL
        THROW 52642, 'sp_resolve_evidence_save: that evidence row was not found on this practice instance.', 1;

    -- The owner picker is filled from the shared lookups feed, which is
    -- not scoped to one organization. Verify before writing the name.
    DECLARE @owner_name NVARCHAR(200) = NULL;
    IF @owner_employee_id IS NOT NULL
    BEGIN
        SELECT @owner_name = e.employee_name
        FROM   grac_practice.organization_employee e
        WHERE  e.employee_id     = @owner_employee_id
          AND  e.organization_id = @organization_id
          AND  e.status          = N'Active';

        IF @owner_name IS NULL
            THROW 52643, 'sp_resolve_evidence_save: the evidence owner must be an active employee of this organization.', 1;
    END

    IF @collection_method_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM grac_practice.collection_method_master
                        WHERE collection_method_id = @collection_method_id AND is_active = 1)
        THROW 52644, 'sp_resolve_evidence_save: that collection method does not exist.', 1;

    IF @collection_frequency_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM grac_practice.frequency_master
                        WHERE frequency_id = @collection_frequency_id AND is_active = 1)
        THROW 52645, 'sp_resolve_evidence_save: that collection frequency does not exist.', 1;

    -- 481: the three options the Operationalize evidence row offers.
    SET @evidence_source = NULLIF(LTRIM(RTRIM(@evidence_source)), N'');
    IF @evidence_source IS NOT NULL
       AND @evidence_source NOT IN (N'DirectUpload', N'EvidenceCenter', N'External')
        THROW 52920, 'Choose how the evidence is provided: Direct Upload, Evidence Center Reference or External Evidence Reference.', 1;

    -- Alignment: once the organization sets any of its own parameters the
    -- row is no longer what the repository published. Worked out from the
    -- values after the update rather than taken from the caller.
    DECLARE @org_defined_id INT = (
        SELECT TOP 1 alignment_status_id FROM grac_practice.evidence_alignment_status_master
        WHERE is_active = 1 AND alignment_status_code = N'Organization Defined'
        ORDER BY alignment_status_id);
    DECLARE @inherited_id INT = (
        SELECT TOP 1 alignment_status_id FROM grac_practice.evidence_alignment_status_master
        WHERE is_active = 1 AND alignment_status_code = N'Inherited'
        ORDER BY alignment_status_id);

    UPDATE e
       SET is_mandatory            = COALESCE(@is_mandatory, e.is_mandatory),
           collection_method_id    = COALESCE(@collection_method_id, e.collection_method_id),
           collection_frequency_id = COALESCE(@collection_frequency_id, e.collection_frequency_id),
           assurance_type_id       = COALESCE(@assurance_type_id, e.assurance_type_id),
           retention_period        = COALESCE(@retention_period, e.retention_period),
           evidence_owner          = CASE WHEN @clear_owner = 1 THEN NULL
                                          ELSE COALESCE(@owner_name, e.evidence_owner) END,
           evidence_name           = COALESCE(@evidence_name, e.evidence_name),
           evidence_description    = CASE WHEN @clear_evidence_description = 1 THEN NULL
                                          ELSE COALESCE(@evidence_description, e.evidence_description) END,
           evidence_location       = COALESCE(@evidence_location, e.evidence_location),
           evidence_locator        = COALESCE(@evidence_locator, e.evidence_locator),
           evidence_source         = COALESCE(@evidence_source, e.evidence_source),   -- 481
           organization_modified   = 1,
           alignment_status_id     = COALESCE(@org_defined_id, e.alignment_status_id),
           updated_by              = @actor,
           updated_dt              = SYSUTCDATETIME()
    FROM   grac_practice.practice_instance_evidence e
    WHERE  e.evidence_id          = @evidence_id
      AND  e.practice_instance_id = @practice_instance_id;

    -- A row that was only ever touched to blank things back out is
    -- inherited again; saying otherwise would overstate what the
    -- organization has decided. Migration 254 adds the name to this test
    -- for the same reason evidence_description is already in it.
    UPDATE e
       SET organization_modified = 0,
           alignment_status_id   = COALESCE(@inherited_id, e.alignment_status_id)
    FROM   grac_practice.practice_instance_evidence e
    WHERE  e.evidence_id          = @evidence_id
      AND  e.practice_instance_id = @practice_instance_id
      AND  e.inherited_from_repository = 1
      AND  NULLIF(LTRIM(RTRIM(ISNULL(e.evidence_location,    N''))), N'') IS NULL
      AND  NULLIF(LTRIM(RTRIM(ISNULL(e.evidence_locator,     N''))), N'') IS NULL
      AND  NULLIF(LTRIM(RTRIM(ISNULL(e.evidence_owner,       N''))), N'') IS NULL
      AND  NULLIF(LTRIM(RTRIM(ISNULL(e.evidence_name,        N''))), N'') IS NULL
      AND  NULLIF(LTRIM(RTRIM(ISNULL(e.evidence_description, N''))), N'') IS NULL
      -- 481: a file uploaded or linked here is the organisation's answer
      -- too, so a row carrying one is not "inherited again".
      AND  NOT EXISTS (SELECT 1 FROM grac_practice.evidence_link l
                        WHERE l.target_type = N'InstanceEvidence'
                          AND l.target_id   = e.evidence_id
                          AND l.status      = N'Active');

    SELECT CAST(1 AS BIT) AS Success,
           e.evidence_id  AS EvidenceId,
           -- 481: the same per-source rule sp_resolve_evidence_list applies.
           grac_practice.fn_pm_instance_evidence_is_resolved(
               e.evidence_source, e.evidence_location, e.evidence_locator, e.evidence_id) AS IsResolved,
           (SELECT COUNT(*) FROM grac_practice.practice_instance_evidence x
             WHERE x.practice_instance_id = @practice_instance_id
               AND x.status = N'Active'
               AND grac_practice.fn_pm_instance_evidence_is_resolved(
                       x.evidence_source, x.evidence_location, x.evidence_locator, x.evidence_id) = 1) AS ResolvedOnInstance,
           e.evidence_source AS EvidenceSource,   -- 481
           N'Evidence saved.' AS Message
    FROM   grac_practice.practice_instance_evidence e
    WHERE  e.evidence_id = @evidence_id;
END
GO


-- =====================================================================
-- 6. Verification
-- =====================================================================
SELECT '481 column evidence_source' AS Check_,
       CASE WHEN COL_LENGTH('grac_practice.practice_instance_evidence','evidence_source') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result_
UNION ALL
SELECT '481 function',
       CASE WHEN OBJECT_ID('grac_practice.fn_pm_instance_evidence_is_resolved') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '481 sp_resolve_evidence_list uses the rule',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_resolve_evidence_list'))
                 LIKE '%fn_pm_instance_evidence_is_resolved%EvidenceSource%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '481 sp_resolve_evidence_save takes @evidence_source',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_resolve_evidence_save'))
                 LIKE '%@evidence_source%fn_pm_instance_evidence_is_resolved%'
            THEN 'PASS' ELSE 'FAIL' END;

-- How existing rows were classified, per organisation and cadence.
SELECT e.organization_id                         AS OrganizationId,
       ISNULL(c.EvidenceCadence, N'(none)')       AS Cadence,
       ISNULL(e.evidence_source, N'(not chosen)') AS EvidenceSource,
       COUNT(*)                                   AS Rows_,
       SUM(CAST(grac_practice.fn_pm_instance_evidence_is_resolved(
               e.evidence_source, e.evidence_location, e.evidence_locator, e.evidence_id) AS INT)) AS Resolved
FROM   grac_practice.practice_instance_evidence e
LEFT   JOIN grac_practice.vw_pm_instance_evidence_cadence c ON c.evidence_id = e.evidence_id
WHERE  e.status = N'Active'
GROUP  BY e.organization_id, c.EvidenceCadence, e.evidence_source
ORDER  BY e.organization_id, Cadence, EvidenceSource;

PRINT '481 evidence source options complete. Deploy API + Web next.';
GO

SET NOEXEC OFF;
GO
