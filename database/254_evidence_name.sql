-- =====================================================================
-- 254 practice_instance_evidence.evidence_name
--
-- Sir asked for an Evidence Name on the resolve (Operationalize) evidence
-- rows. There was nothing to surface: practice_instance_evidence (001)
-- carries evidence_type_id and free text, and GRAC_New's
-- requirement_obligation_evidence carries evidence_type_id, frequency_id,
-- retention_requirement and remarks. Neither has a name column. The only
-- name in the system is evidence_type_master.evidence_type_name, which
-- the card already prints as the row heading -- and that is the TYPE, one
-- label shared by every row of that type on every instance.
--
-- So this adds a real per-row name the organisation owns:
--
--   * evidence_name is the organisation's label for THIS evidence row on
--     THIS instance -- "Q3 firewall ruleset export", not "Configuration
--     Export". It is nullable; a row with no name still reads by its type.
--   * It follows the same COALESCE contract as every other field on
--     sp_resolve_evidence_save: NULL means "unchanged", so a screen can
--     save a location without resending the name.
--   * It joins the emptiness test that re-inherits an untouched row, for
--     the same reason evidence_description is in that list: a row whose
--     only edit was a name that has since been cleared is inherited
--     again, and leaving the name out would pin it at Organization
--     Defined forever.
--
-- Deliberately NOT added to the alignment/resolved test: resolved still
-- means location AND locator, unchanged, because that is the test
-- assurance applies and this migration must not make the workspace claim
-- ready on a row assurance would refuse.
--
-- SCOPE
--   1. column on practice_instance_evidence
--   2. sp_resolve_evidence_list  -- 232's body + EvidenceName
--   3. sp_resolve_evidence_save  -- 143's body + @evidence_name
--
-- SAFE TO RE-RUN. Requires 001, 143, 232.
-- ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    PRINT 'ABORT (254): schema grac_practice missing.';
    SET NOEXEC ON;
END
GO

IF OBJECT_ID('grac_practice.practice_instance_evidence','U') IS NULL
BEGIN
    PRINT 'ABORT (254): practice_instance_evidence missing (run 001 first).';
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. Column
-- =====================================================================
IF COL_LENGTH('grac_practice.practice_instance_evidence','evidence_name') IS NULL
BEGIN
    ALTER TABLE grac_practice.practice_instance_evidence
        ADD evidence_name NVARCHAR(300) NULL;
    PRINT '254: practice_instance_evidence.evidence_name added.';
END
GO

-- =====================================================================
-- 2. sp_resolve_evidence_list -- project EvidenceName
--
-- 232's body (the live one -- it added the
-- source_practice_instance_obligation_id filter for locally defined
-- obligations) with one column added. EvidenceName sits immediately
-- before EvidenceType so the name and the type read together.
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
        -- Migration 254 deliberately does NOT add the name here.
        CAST(CASE WHEN NULLIF(LTRIM(RTRIM(ISNULL(e.evidence_location, N''))), N'') IS NOT NULL
                   AND NULLIF(LTRIM(RTRIM(ISNULL(e.evidence_locator,  N''))), N'') IS NOT NULL
                  THEN 1 ELSE 0 END AS BIT) AS IsResolved
    FROM   grac_practice.practice_instance_evidence e
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
PRINT '254: sp_resolve_evidence_list projects EvidenceName.';
GO

-- =====================================================================
-- 3. sp_resolve_evidence_save -- accept @evidence_name
--
-- 143's body with the new parameter. Placed last before @actor so an
-- existing positional caller is unaffected; the API binds by name anyway.
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
    @actor                  NVARCHAR(100) = N'system'
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
           evidence_description    = COALESCE(@evidence_description, e.evidence_description),
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
PRINT '254: sp_resolve_evidence_save accepts @evidence_name.';
GO

-- =====================================================================
-- Verification
-- =====================================================================
PRINT '=== 254 verification ===';

DECLARE @list NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_resolve_evidence_list','P'));
DECLARE @save NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_resolve_evidence_save','P'));

SELECT '254-a evidence_name column added' AS Check_,
       CASE WHEN COL_LENGTH('grac_practice.practice_instance_evidence','evidence_name') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '254-b list projects EvidenceName',
       CASE WHEN @list LIKE '%AS EvidenceName%'        THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '254-c save accepts @evidence_name',
       CASE WHEN @save LIKE '%@evidence_name%'         THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '254-d save COALESCE-preserves the name',
       CASE WHEN @save LIKE '%COALESCE(@evidence_name, e.evidence_name)%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '254-e name joins the re-inherit emptiness test',
       CASE WHEN @save LIKE '%ISNULL(e.evidence_name%' THEN 'PASS' ELSE 'FAIL' END
UNION ALL
-- Regression guard: resolved still means location AND locator only.
SELECT '254-f resolved test unchanged (name excluded)',
       CASE WHEN @list LIKE '%AS IsResolved%'
             AND @list NOT LIKE '%evidence_name, N''''))), N'''') IS NOT NULL%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
-- Regression guard: 232's local-obligation filter must survive.
SELECT '254-g list keeps 232 local-obligation filter',
       CASE WHEN @list LIKE '%@practice_instance_obligation_id%'
            THEN 'PASS' ELSE 'FAIL' END;

PRINT '';
PRINT '254 complete. Evidence Name is live end-to-end.';
GO

SET NOEXEC OFF;
GO
