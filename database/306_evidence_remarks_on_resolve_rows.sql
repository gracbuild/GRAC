-- =====================================================================
-- 306 Evidence remark on the resolve workspace evidence row
--
-- WHAT WAS WRONG
-- --------------
-- The published remark on a piece of evidence -- roe.remarks, the
-- authority's instruction for what the evidence has to show -- was
-- visible in exactly the wrong half of the workspace.
--
--   * Obligation NOT yet adopted: the Evidence panel lists what the
--     authority publishes, and prints the remark under each type.
--     (resolve-workspace.cshtml, publishedEvidenceOf -> p.remark)
--   * Obligation adopted, rows created: the panel switches to the real
--     practice_instance_evidence rows -- and the remark disappears,
--     because sp_resolve_evidence_list never projected it.
--
-- So the instruction vanished at exactly the moment the operator started
-- filling the evidence in. Sir asked for it under the Evidence Name.
--
-- WHERE THE REMARK LIVES
-- ----------------------
-- GRAC_New.requirement_obligation_evidence.remarks, per published
-- evidence row. Migration 254's own header says so, and 224 / 302 already
-- project it as Remarks into the typed detail view's EvidenceJson --
-- which is where the not-yet-adopted branch reads it from. This migration
-- brings the same value onto the adopted row.
--
-- HOW THE ROW IS MATCHED
-- ----------------------
--   1. practice_instance_evidence.source_obligation_evidence_id (added by
--      140, written by every adopt path since 141) -> the exact published
--      row. This is the answer whenever it is set.
--   2. Fallback for rows where it is NULL -- added by hand on the
--      Practice Instance form, or claimed by the 231/304 "attach an
--      unattached row of the right type" UPDATE, which sets
--      source_obligation_id but not the evidence id. Matched on
--      obligation + evidence type through vw_pm_obligation_evidence and
--      the evidence_type_name bridge between the two catalogues -- the
--      SAME join 304's reconcile uses, not a new rule.
--
-- Blank remarks resolve to NULL (NULLIF on the trimmed value) so the
-- screen shows nothing rather than an empty line, and the fallback skips
-- a blank published row in favour of one that actually says something.
--
-- SCOPE
--   sp_resolve_evidence_list -- 254's body + EvidenceRemarks. Nothing
--   else. No schema change: the column is a projection of published data,
--   not organisation-owned state, so there is nothing to store and
--   nothing for sp_resolve_evidence_save to accept.
--
-- WHY NOT A STORED COLUMN
--   A copy taken at adoption time would go stale the moment Control
--   Management edits the remark, and the operator would be reading an
--   instruction the authority has since changed. Read it live.
--
-- SAFE TO RE-RUN. Requires 254 (the proc body this extends), 144
-- (vw_pm_obligation_evidence) and the GRAC_New repository tables.
-- Rollback: database/306_evidence_remarks_on_resolve_rows_rollback.sql
-- ASCII-only on purpose: sqlcmd reads files in the current ANSI codepage
-- by default and multi-byte characters can corrupt string literals.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;   -- defensive: reset in case a prior script left it on
GO

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    PRINT 'ABORT (306): schema grac_practice missing. Run base scripts first.';
    SET NOEXEC ON;
END
GO

IF OBJECT_ID('grac_practice.sp_resolve_evidence_list','P') IS NULL
BEGIN
    PRINT 'ABORT (306): sp_resolve_evidence_list missing -- run 254 first.';
    SET NOEXEC ON;
END
GO

IF OBJECT_ID('grac_practice.vw_pm_obligation_evidence','V') IS NULL
BEGIN
    PRINT 'ABORT (306): vw_pm_obligation_evidence missing -- run 144 first.';
    SET NOEXEC ON;
END
GO

IF COL_LENGTH('grac_practice.practice_instance_evidence','source_obligation_evidence_id') IS NULL
BEGIN
    PRINT 'ABORT (306): practice_instance_evidence.source_obligation_evidence_id missing -- run 140 first.';
    SET NOEXEC ON;
END
GO

-- 306 re-issues 254's proc body, which reads e.evidence_name. On a
-- database that never ran 254 the column does not exist and every
-- statement touching it fails with Msg 207 "Invalid column name
-- 'evidence_name'" -- while the PRINTs after it still run, so the script
-- LOOKS like it half-succeeded. It did not: CREATE OR ALTER aborts on
-- Msg 207 and the old body stays deployed.
--
-- Checking the column, not just the procedure, is the difference. And the
-- fix is 254 rather than an ALTER here: 254 also re-issues
-- sp_resolve_evidence_save with @evidence_name, so adding only the column
-- would leave the Evidence name box on screen unable to save what the
-- operator typed into it.
IF COL_LENGTH('grac_practice.practice_instance_evidence','evidence_name') IS NULL
BEGIN
    PRINT 'ABORT (306): practice_instance_evidence.evidence_name missing.';
    PRINT '             Run database/254_evidence_name.sql first, then re-run 306.';
    PRINT '             254 adds the column AND teaches sp_resolve_evidence_save';
    PRINT '             to accept it; 306 only extends the list procedure.';
    SET NOEXEC ON;
END
GO

IF OBJECT_ID('GRAC_New.requirement_obligation_evidence','U') IS NULL
BEGIN
    PRINT 'ABORT (306): GRAC_New.requirement_obligation_evidence not reachable.';
    PRINT '             The remark is published repository data -- there is';
    PRINT '             nothing to project without it. 254 stays in place.';
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- sp_resolve_evidence_list -- 254's body with EvidenceRemarks added
--
-- 254 is the live definition (it added EvidenceName over 232's body,
-- which added the @practice_instance_obligation_id filter over 143).
-- Every other column, join, filter and the ORDER BY are the 254 text
-- unchanged; EvidenceRemarks sits after EvidenceType so the name, the
-- type and the instruction read together.
--
-- The remark is a correlated scalar subquery rather than a join, so it
-- cannot fan the row set out -- one published evidence row can be reached
-- by several link tables (see 302), and a join would duplicate the
-- evidence row on the screen.
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
             FROM   GRAC_New.requirement_obligation_evidence roe
             WHERE  roe.obligation_evidence_id = e.source_obligation_evidence_id
               AND  roe.status = N'Active'),
            (SELECT TOP 1 NULLIF(LTRIM(RTRIM(CAST(roe2.remarks AS NVARCHAR(MAX)))), N'')
             FROM   grac_practice.vw_pm_obligation_evidence oe
             JOIN   GRAC_New.requirement_obligation_evidence roe2
                    ON roe2.obligation_evidence_id = oe.obligation_evidence_id
             JOIN   GRAC_New.evidence_type_master get
                    ON get.evidence_type_id = oe.evidence_type_id
             JOIN   grac_practice.evidence_type_master pet
                    ON pet.evidence_type_name = get.evidence_type_name
                   AND pet.is_active = 1
             WHERE  oe.obligation_id      = e.source_obligation_id
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
PRINT '306: sp_resolve_evidence_list projects EvidenceRemarks.';
GO

-- =====================================================================
-- Verification
-- =====================================================================
PRINT '=== 306 verification ===';

DECLARE @list NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_resolve_evidence_list','P'));

SELECT '306-a list projects EvidenceRemarks' AS Check_,
       CASE WHEN @list LIKE '%AS EvidenceRemarks%' THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '306-b exact match on source_obligation_evidence_id',
       CASE WHEN @list LIKE '%roe.obligation_evidence_id = e.source_obligation_evidence_id%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '306-c obligation + type fallback present',
       CASE WHEN @list LIKE '%vw_pm_obligation_evidence oe%' THEN 'PASS' ELSE 'FAIL' END
UNION ALL
-- Regression guards: everything 254 and 232 established must survive.
SELECT '306-d 254 EvidenceName still projected',
       CASE WHEN @list LIKE '%AS EvidenceName%' THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '306-e 232 local-obligation filter kept',
       CASE WHEN @list LIKE '%@practice_instance_obligation_id%' THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '306-f resolved test unchanged (remark excluded)',
       CASE WHEN @list LIKE '%AS IsResolved%'
             AND @list NOT LIKE '%remarks, N''''))), N'''') IS NOT NULL%'
            THEN 'PASS' ELSE 'FAIL' END;

-- Live sample: the first ten rows that now carry a remark. Empty on a
-- database whose repository publishes none, which is not a failure.
SELECT TOP 10
       'Sample' AS Check_,
       e.evidence_id  AS EvidenceId,
       e.evidence_name AS EvidenceName,
       et.evidence_type_name AS EvidenceType,
       LEFT(CAST(roe.remarks AS NVARCHAR(4000)), 120) AS RemarkStart
FROM   grac_practice.practice_instance_evidence e
LEFT   JOIN grac_practice.evidence_type_master et
       ON et.evidence_type_id = e.evidence_type_id
JOIN   GRAC_New.requirement_obligation_evidence roe
       ON roe.obligation_evidence_id = e.source_obligation_evidence_id
      AND roe.status = N'Active'
WHERE  e.status = N'Active'
  AND  NULLIF(LTRIM(RTRIM(CAST(roe.remarks AS NVARCHAR(4000)))), N'') IS NOT NULL
ORDER  BY e.evidence_id DESC;

PRINT '';
PRINT '306 complete. The published remark now reads under Evidence Name.';
GO

SET NOEXEC OFF;
GO
