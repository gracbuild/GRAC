-- =====================================================================
-- 232 Evidence on an organisation-defined obligation -- ROLLBACK
--
-- Undoes database/232_local_obligation_evidence.sql:
--   1. Restores sp_resolve_local_obligation_save to the 227 body (no
--      evidence list, and retiring an obligation no longer retires its
--      evidence).
--   2. Restores sp_resolve_evidence_list to the 143 body (no
--      SourcePracticeInstanceObligationId, no local filter).
--   3. Drops sp_resolve_local_obligation_evidence_sync.
--
-- THE EVIDENCE ROWS STAY
-- ----------------------
-- Rows already created for an organisation-defined obligation are that
-- organisation's own compliance evidence. They keep their
-- source_practice_instance_obligation_id -- nothing reads it once the
-- procedures above are restored, so it costs nothing, and discarding
-- which obligation each row belongs to is not something a rollback
-- should decide.
--
-- They become invisible on the workspace, because the restored evidence
-- list has no way to attach them to a local obligation. Re-running 232
-- brings them back.
--
-- REVERT THE APP FIRST. The Web tier posts an `evidence` array and the
-- modal reads SourcePracticeInstanceObligationId; with the procedures
-- restored the array is rejected as an unknown parameter.
--
-- ASCII-only on purpose (see the forward script header).
-- Idempotent: safe to re-run.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    PRINT 'ABORT (232 rollback): schema grac_practice missing.';
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. sp_resolve_local_obligation_save -- back to the 227 body.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_resolve_local_obligation_save
    @practice_instance_id            BIGINT,
    @practice_instance_obligation_id BIGINT        = 0,
    @obligation_name                 NVARCHAR(500) = NULL,
    @obligation_description          NVARCHAR(MAX) = NULL,
    @obligation_type_code            NVARCHAR(60)  = NULL,
    @typed_detail_json               NVARCHAR(MAX) = NULL,
    @execution_frequency_id          INT           = NULL,
    @execution_frequency             NVARCHAR(120) = NULL,
    @responsibility                  NVARCHAR(300) = NULL,
    @approval_authority              NVARCHAR(300) = NULL,
    @assurance_type                  NVARCHAR(40)  = NULL,
    @remarks                         NVARCHAR(MAX) = NULL,
    @retire                          BIT           = 0,
    @caller_employee_id              BIGINT        = NULL,
    @is_admin                        BIT           = 0,
    @actor                           NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @practice_instance_id IS NULL
        THROW 52691, 'sp_resolve_local_obligation_save: practice_instance_id is required.', 1;

    DECLARE @organization_id BIGINT, @owner_id BIGINT;
    SELECT @organization_id = organization_id, @owner_id = primary_owner_id
    FROM   grac_practice.practice_instance
    WHERE  practice_instance_id = @practice_instance_id;

    IF @organization_id IS NULL
        THROW 52692, 'sp_resolve_local_obligation_save: instance not found.', 1;

    -- Same ownership test every other Resolve procedure applies.
    IF @is_admin = 0 AND ISNULL(@owner_id, -1) <> ISNULL(@caller_employee_id, -2)
        THROW 52693, 'sp_resolve_local_obligation_save: this practice instance belongs to another owner.', 1;

    -- ---- retire ----
    IF @retire = 1
    BEGIN
        IF @practice_instance_obligation_id IS NULL OR @practice_instance_obligation_id = 0
            THROW 52694, 'sp_resolve_local_obligation_save: an id is required to retire an obligation.', 1;

        UPDATE grac_practice.practice_instance_obligation
           SET status     = N'Retired',
               updated_by = @actor,
               updated_dt = SYSUTCDATETIME()
         WHERE practice_instance_obligation_id = @practice_instance_obligation_id
           AND practice_instance_id            = @practice_instance_id
           AND obligation_id IS NULL;

        IF @@ROWCOUNT = 0
            THROW 52695, 'sp_resolve_local_obligation_save: no organisation-defined obligation with that id on this instance.', 1;

        SELECT CAST(1 AS BIT) AS Success, N'Obligation removed.' AS Message,
               @practice_instance_obligation_id AS PracticeInstanceObligationId;
        RETURN;
    END

    -- ---- validate ----
    SET @obligation_name = NULLIF(LTRIM(RTRIM(@obligation_name)), N'');
    IF @obligation_name IS NULL
        THROW 52696, 'Obligation name is required.', 1;

    SET @obligation_type_code = NULLIF(LTRIM(RTRIM(@obligation_type_code)), N'');
    IF @obligation_type_code IS NULL
        THROW 52697, 'Obligation type is required.', 1;

    IF NOT EXISTS (SELECT 1 FROM GRAC_New.obligation_type_master
                    WHERE type_code = @obligation_type_code)
        THROW 52698, 'That obligation type does not exist.', 1;

    IF @typed_detail_json IS NOT NULL AND ISJSON(@typed_detail_json) <> 1
        THROW 52699, 'The rule detail must be valid JSON.', 1;

    IF @assurance_type IS NOT NULL AND @assurance_type NOT IN (N'Manual', N'Automated')
        THROW 52674, 'Assurance type must be Manual or Automated.', 1;

    DECLARE @active_record_status_id INT = (
        SELECT TOP 1 record_status_id FROM grac_practice.record_status_master
        WHERE status_code = N'ACTIVE' OR status_name = N'Active' ORDER BY record_status_id);

    -- ---- add ----
    IF ISNULL(@practice_instance_obligation_id, 0) = 0
    BEGIN
        INSERT grac_practice.practice_instance_obligation
            (organization_id, practice_instance_id, obligation_id, release_id,
             obligation_name, obligation_description, obligation_type_code,
             typed_detail_json,
             inherited_from_repository, organization_modified,
             execution_frequency_id, execution_frequency,
             responsibility, approval_authority, assurance_type, remarks,
             adopted_by, adopted_dt, status, record_status_id, entered_by)
        VALUES
            (@organization_id, @practice_instance_id, NULL, NULL,
             @obligation_name, @obligation_description, @obligation_type_code,
             ISNULL(@typed_detail_json, N'[]'),
             -- Not inherited, and organisation-defined is by definition
             -- an organisation modification.
             0, 1,
             @execution_frequency_id, @execution_frequency,
             @responsibility, @approval_authority, @assurance_type, @remarks,
             @actor, SYSUTCDATETIME(), N'Active', @active_record_status_id, @actor);

        SET @practice_instance_obligation_id = SCOPE_IDENTITY();

        SELECT CAST(1 AS BIT) AS Success, N'Obligation added.' AS Message,
               @practice_instance_obligation_id AS PracticeInstanceObligationId;
        RETURN;
    END

    -- ---- edit ----
    UPDATE grac_practice.practice_instance_obligation
       SET obligation_name        = @obligation_name,
           obligation_description = @obligation_description,
           obligation_type_code   = @obligation_type_code,
           typed_detail_json      = ISNULL(@typed_detail_json, typed_detail_json),
           execution_frequency_id = @execution_frequency_id,
           execution_frequency    = @execution_frequency,
           responsibility         = @responsibility,
           approval_authority     = @approval_authority,
           assurance_type         = @assurance_type,
           remarks                = @remarks,
           status                 = N'Active',
           updated_by             = @actor,
           updated_dt             = SYSUTCDATETIME()
     WHERE practice_instance_obligation_id = @practice_instance_obligation_id
       AND practice_instance_id            = @practice_instance_id
       -- The guard that matters: this door only opens on locally added
       -- rows. An adopted published obligation is edited through
       -- sp_resolve_obligation_adopt, which derives organization_modified
       -- against what was published -- a concept a local row has no
       -- counterpart for.
       AND obligation_id IS NULL;

    IF @@ROWCOUNT = 0
        THROW 52695, 'sp_resolve_local_obligation_save: no organisation-defined obligation with that id on this instance.', 1;

    SELECT CAST(1 AS BIT) AS Success, N'Obligation saved.' AS Message,
           @practice_instance_obligation_id AS PracticeInstanceObligationId;
END
GO

PRINT '232 rollback: sp_resolve_local_obligation_save restored to the 227 body.';
GO

-- =====================================================================
-- 2. sp_resolve_evidence_list -- back to the 143 body.
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

PRINT '232 rollback: sp_resolve_evidence_list restored to the 143 body.';
GO

-- =====================================================================
-- 3. Drop the sync procedure.
-- =====================================================================
IF OBJECT_ID('grac_practice.sp_resolve_local_obligation_evidence_sync','P') IS NOT NULL
BEGIN
    DROP PROCEDURE grac_practice.sp_resolve_local_obligation_evidence_sync;
    PRINT '232 rollback: sp_resolve_local_obligation_evidence_sync dropped.';
END
GO

-- =====================================================================
-- 4. Verification
-- =====================================================================
PRINT '=== 232 rollback verification ===';

DECLARE @orphaned INT = 0;
IF COL_LENGTH('grac_practice.practice_instance_evidence','source_practice_instance_obligation_id') IS NOT NULL
    SELECT @orphaned = COUNT(*)
    FROM   grac_practice.practice_instance_evidence
    WHERE  source_practice_instance_obligation_id IS NOT NULL
      AND  status = N'Active';

SELECT 'sync procedure removed' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.sp_resolve_local_obligation_evidence_sync','P') IS NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT 'local save no longer takes an evidence list',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_resolve_local_obligation_save','P'))
                 LIKE '%@evidence_json%'
            THEN 'FAIL' ELSE 'PASS' END
UNION ALL
SELECT 'evidence rows kept but now unreachable',
       CAST(@orphaned AS NVARCHAR(20)) + ' row(s) -- re-run 232 to see them again';

PRINT '';
PRINT '232 rollback complete.';
GO

SET NOEXEC OFF;
GO
