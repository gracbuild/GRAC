-- =====================================================================
-- 306 Evidence remark on the resolve workspace evidence row -- ROLLBACK
--
-- Re-issues sp_resolve_evidence_list from 254's body, byte for byte,
-- dropping the EvidenceRemarks column. Nothing else to undo: 306 made no
-- schema change and stored nothing.
--
-- The API reads EvidenceRemarks with the same OptionalString guard
-- EvidenceName uses, so the app keeps working against this body and the
-- remark simply stops appearing.
--
-- SAFE TO RE-RUN. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    PRINT 'ABORT (306 rollback): schema grac_practice missing.';
    SET NOEXEC ON;
END
GO

IF OBJECT_ID('grac_practice.practice_instance_evidence','U') IS NULL
BEGIN
    PRINT 'ABORT (306 rollback): practice_instance_evidence missing.';
    SET NOEXEC ON;
END
GO

-- The body below is 254's, so it reads e.evidence_name. Without the
-- column, CREATE OR ALTER fails with Msg 207 and the deployed procedure
-- is left as-is -- checked here so the failure is a sentence rather than
-- five parser errors.
IF COL_LENGTH('grac_practice.practice_instance_evidence','evidence_name') IS NULL
BEGIN
    PRINT 'ABORT (306 rollback): practice_instance_evidence.evidence_name missing.';
    PRINT '                      This database never ran 254, so it never ran 306';
    PRINT '                      either -- there is nothing to roll back.';
    SET NOEXEC ON;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_resolve_evidence_list
    @practice_instance_id BIGINT,
    @obligation_id        BIGINT = NULL,
    @practice_instance_obligation_id BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @practice_instance_id IS NULL
        THROW 52640, 'sp_resolve_evidence_list: practice_instance_id is required.', 1;

    SELECT
        e.evidence_id             AS EvidenceId,
        e.source_obligation_id    AS SourceObligationId,
        e.source_practice_instance_obligation_id AS SourcePracticeInstanceObligationId,
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
              COALESCE(NULLIF(LTRIM(RTRIM(e.evidence_name)), N''), et.evidence_type_name);
END
GO

PRINT '306 rollback: sp_resolve_evidence_list restored to the 254 body.';

DECLARE @list NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_resolve_evidence_list','P'));

SELECT '306 rollback-a EvidenceRemarks removed' AS Check_,
       CASE WHEN @list NOT LIKE '%EvidenceRemarks%' THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '306 rollback-b 254 EvidenceName intact',
       CASE WHEN @list LIKE '%AS EvidenceName%' THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '306 rollback-c 232 local-obligation filter intact',
       CASE WHEN @list LIKE '%@practice_instance_obligation_id%' THEN 'PASS' ELSE 'FAIL' END;
GO

SET NOEXEC OFF;
GO
