-- =====================================================================
-- 143 Resolve workspace -- evidence resolution
--
-- 141 creates evidence rows when an obligation is adopted, and the card
-- shows how many of them are resolved. It never gave anyone a way to
-- resolve one. This adds the two procedures behind that:
--
--   grac_practice.sp_resolve_evidence_list   rows for the instance
--   grac_practice.sp_resolve_evidence_save   fill one in
--
-- WHAT "RESOLVED" MEANS
-- ---------------------
-- Both a location and a locator are present. That is not an invented
-- rule: the assurance-eligible-instances query in
-- pm_get_practice_repository already requires exactly those two before
-- an instance can be assured. Any other definition here would let the
-- workspace call an instance ready that assurance then refuses.
--
-- ALIGNMENT IS DERIVED, NOT SUPPLIED
-- ----------------------------------
-- evidence_alignment_status says how the organization's evidence relates
-- to what the authority published: Inherited when it is untouched,
-- Organization Defined once a published parameter has been changed. The
-- procedure works that out from the values themselves. A caller-supplied
-- alignment would let a screen label an edited row as inherited, and
-- that column exists precisely to answer that question honestly.
--
-- THE OWNER IS PICKED BY ID AND STORED BY NAME
-- --------------------------------------------
-- practice_instance_evidence.evidence_owner is a name column, and the
-- existing form fills it from the `users` lookup whose value IS the
-- name. Names are not unique and not checkable, so this procedure takes
-- an employee id, verifies it belongs to this organization, and writes
-- that employee's name. Same column, same shape on the screen, but the
-- value can no longer be a person from somewhere else.
--
-- Error codes 52640-52649. Depends on 140 (source_obligation_id) and 141.
-- Rollback: 143_resolve_evidence_procs_rollback.sql.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.practice_instance_evidence','U') IS NULL
   OR COL_LENGTH('grac_practice.practice_instance_evidence','source_obligation_id') IS NULL
BEGIN
    RAISERROR('143: practice_instance_evidence.source_obligation_id missing. Run 140 first.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. sp_resolve_evidence_list
--
--    All evidence rows for the instance, with the obligation that
--    produced each one so the workspace can group them under their card.
--    Hand-added rows (source_obligation_id NULL) come back too -- they
--    are just as much part of what has to be collected.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_resolve_evidence_list
    @practice_instance_id BIGINT,
    @obligation_id        BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @practice_instance_id IS NULL
        THROW 52640, 'sp_resolve_evidence_list: practice_instance_id is required.', 1;

    SELECT
        e.evidence_id             AS EvidenceId,
        e.source_obligation_id    AS SourceObligationId,
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
    ORDER  BY CASE WHEN e.source_obligation_id IS NULL THEN 1 ELSE 0 END,
              e.source_obligation_id,
              et.evidence_type_name;
END
GO

-- =====================================================================
-- 2. sp_resolve_evidence_save
--
--    Updates one evidence row. Every parameter is optional except the
--    row itself: NULL means "leave as it is", so the screen can save a
--    single field without resending everything it did not touch.
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
    -- organization has decided.
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

-- =====================================================================
-- Sanity report
-- =====================================================================
SELECT 'sp_resolve_evidence_list' AS Object_,
       CASE WHEN OBJECT_ID('grac_practice.sp_resolve_evidence_list','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL SELECT 'sp_resolve_evidence_save',
       CASE WHEN OBJECT_ID('grac_practice.sp_resolve_evidence_save','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT 'Organization Defined alignment seeded',
       CASE WHEN EXISTS (SELECT 1 FROM grac_practice.evidence_alignment_status_master
                          WHERE alignment_status_code = N'Organization Defined')
            THEN 'PASS' ELSE 'FAIL -- alignment will stay as it was' END;

-- How much evidence is waiting, per instance. Location and locator are
-- what assurance needs, so anything above zero here is real outstanding
-- work rather than a cosmetic gap.
SELECT e.practice_instance_id AS PracticeInstanceId,
       pi.instance_code       AS InstanceCode,
       COUNT(*)               AS EvidenceRows,
       SUM(CASE WHEN NULLIF(LTRIM(RTRIM(ISNULL(e.evidence_location, N''))), N'') IS NOT NULL
                 AND NULLIF(LTRIM(RTRIM(ISNULL(e.evidence_locator,  N''))), N'') IS NOT NULL
                THEN 1 ELSE 0 END) AS Resolved
FROM   grac_practice.practice_instance_evidence e
JOIN   grac_practice.practice_instance pi ON pi.practice_instance_id = e.practice_instance_id
WHERE  e.status = N'Active'
GROUP  BY e.practice_instance_id, pi.instance_code
ORDER  BY e.practice_instance_id;

PRINT '143 Evidence resolution procedures installed.';
GO
