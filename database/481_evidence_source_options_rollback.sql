-- =====================================================================
-- 481_evidence_source_options_rollback.sql
--
-- Reverses 481:
--   1. Re-issues, verbatim, the 476 sp_resolve_evidence_list body.
--   2. Re-issues, verbatim, the 473 sp_resolve_evidence_save body.
--   3. Drops fn_pm_instance_evidence_is_resolved.
--   4. Drops ck_pm_instance_evidence_source and the evidence_source
--      column (the chosen options are lost; location, locator and
--      Evidence Center links are untouched).
--
-- Deploy the previous API / Web build first: the 481 build sends
-- evidenceSource, which the API binds only when the procedure declares
-- @evidence_source, so it keeps working either way -- but the screen
-- would show options it can no longer store.
-- SAFE TO RE-RUN. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
GO

-- 1. sp_resolve_evidence_list -- the 476 body, verbatim
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

        -- The same two-field test assurance eligibility applies, so the
        -- workspace cannot report ready on a row assurance would reject.
        -- Migration 254 deliberately does NOT add the name here, and 306
        -- does not add the remark: a published instruction is not an
        -- organisation answer, so it cannot move a row towards resolved.
        CAST(CASE WHEN NULLIF(LTRIM(RTRIM(ISNULL(e.evidence_location, N''))), N'') IS NOT NULL
                   AND NULLIF(LTRIM(RTRIM(ISNULL(e.evidence_locator,  N''))), N'') IS NOT NULL
                  THEN 1 ELSE 0 END AS BIT) AS IsResolved,

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


-- 2. sp_resolve_evidence_save -- the 473 body, verbatim
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
    @clear_evidence_description BIT       = 0
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
      AND  NULLIF(LTRIM(RTRIM(ISNULL(e.evidence_description, N''))), N'') IS NULL;

    SELECT CAST(1 AS BIT) AS Success,
           e.evidence_id  AS EvidenceId,
           CAST(CASE WHEN NULLIF(LTRIM(RTRIM(ISNULL(e.evidence_location, N''))), N'') IS NOT NULL
                      AND NULLIF(LTRIM(RTRIM(ISNULL(e.evidence_locator,  N''))), N'') IS NOT NULL
                     THEN 1 ELSE 0 END AS BIT) AS IsResolved,
           (SELECT COUNT(*) FROM grac_practice.practice_instance_evidence x
             WHERE x.practice_instance_id = @practice_instance_id
               AND x.status = N'Active'
               AND NULLIF(LTRIM(RTRIM(ISNULL(x.evidence_location, N''))), N'') IS NOT NULL
               AND NULLIF(LTRIM(RTRIM(ISNULL(x.evidence_locator,  N''))), N'') IS NOT NULL) AS ResolvedOnInstance,
           N'Evidence saved.' AS Message
    FROM   grac_practice.practice_instance_evidence e
    WHERE  e.evidence_id = @evidence_id;
END
GO


-- 3. function
IF OBJECT_ID('grac_practice.fn_pm_instance_evidence_is_resolved') IS NOT NULL
    DROP FUNCTION grac_practice.fn_pm_instance_evidence_is_resolved;
GO

-- 4. constraint + column
IF EXISTS (SELECT 1 FROM sys.check_constraints
           WHERE name = 'ck_pm_instance_evidence_source'
             AND parent_object_id = OBJECT_ID('grac_practice.practice_instance_evidence'))
    ALTER TABLE grac_practice.practice_instance_evidence DROP CONSTRAINT ck_pm_instance_evidence_source;
GO
IF COL_LENGTH('grac_practice.practice_instance_evidence','evidence_source') IS NOT NULL
    ALTER TABLE grac_practice.practice_instance_evidence DROP COLUMN evidence_source;
GO

SELECT '481 rollback' AS Check_,
       CASE WHEN COL_LENGTH('grac_practice.practice_instance_evidence','evidence_source') IS NULL
             AND OBJECT_ID('grac_practice.fn_pm_instance_evidence_is_resolved') IS NULL
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_resolve_evidence_save')) NOT LIKE '%@evidence_source%'
            THEN 'PASS' ELSE 'FAIL' END AS Result_;
PRINT '481 rollback complete.';
GO
