-- =====================================================================
-- Diagnostic: "N evidence types are published, but no row exists here"
--
-- REVISED TWICE. Two hypotheses have been tested and BOTH DISPROVEN by
-- this database:
--
--   1. The catalogues disagree on a NAME.  Ruled out: GRAC_New and
--      grac_practice.evidence_type_master carry the same 20 names, all
--      is_active = 1, and the unmatched-by-name query returned nothing.
--
--   2. A published evidence_type_id is an ORPHAN with no row in
--      GRAC_New.evidence_type_master.  Ruled out: the ten ids actually
--      in use (11-20) all resolve, and the orphan query returned
--      nothing.
--
-- So adoption CAN create a row for every published type. The gap is not
-- in the catalogues, which leaves:
--
--   3. Adoption never created them for this obligation -- the adoption
--      row predates the evidence-creating code (144/231), so the
--      obligation reads as adopted while nothing was ever inserted.
--
--   4. Rows exist but the card cannot see them -- source_obligation_id
--      is NULL (unattached), points at a different obligation, or the
--      row is not Active. The panel filters on sourceObligationId, so
--      any of those looks identical to "no row exists".
--
-- SECTION 1 FINDS THE AFFECTED ROWS ITSELF. No parameter to set: it
-- lists every (instance, obligation) pair that would print the message,
-- and names which of 3 or 4 it is. Sections 2 and 3 drill into one
-- instance once you have picked one from section 1.
--
-- READ-ONLY. Nothing is written. Safe to run on production.
-- =====================================================================
SET NOCOUNT ON;

PRINT '===== 1. Every obligation that would print the message =====';
PRINT '      One row per (instance, obligation) where the obligation is';
PRINT '      adopted, evidence is published, and no Active row exists.';
PRINT '      Diagnosis says which cause it is.';

;WITH published AS (
    -- exactly what the panel calls "published": the bare count, no joins
    SELECT roe.obligation_id,
           COUNT(DISTINCT roe.evidence_type_id) AS PublishedCount
    FROM   GRAC_New.requirement_obligation_evidence roe
    WHERE  roe.evidence_type_id IS NOT NULL
    GROUP  BY roe.obligation_id
),
creatable AS (
    -- how many types survive BOTH inner joins adoption uses
    SELECT oe.obligation_id,
           COUNT(DISTINCT pet.evidence_type_id) AS CreatableTypes
    FROM   grac_practice.vw_pm_obligation_evidence oe
    JOIN   GRAC_New.evidence_type_master get
           ON get.evidence_type_id = oe.evidence_type_id
    JOIN   grac_practice.evidence_type_master pet
           ON pet.evidence_type_name = get.evidence_type_name
          AND pet.is_active = 1
    GROUP  BY oe.obligation_id
),
-- The counts are scalar subqueries, NOT aggregates over a CROSS APPLY.
-- An aggregate may not mix an outer reference with an inner column in one
-- expression -- SUM(CASE WHEN pie.source_obligation_id = pio.obligation_id ...)
-- raises Msg 8124. In a scalar subquery the outer reference sits in the
-- WHERE clause and COUNT(*) aggregates nothing, which is legal, and it is
-- the shape sp_resolve_obligation_adopt's own result SELECT already uses.
--
-- Wrapped in a CTE so the ActiveRows = 0 filter can be applied to the
-- computed column; a SELECT alias is not visible to its own WHERE.
candidates AS (
    SELECT pio.practice_instance_id                    AS PracticeInstanceId,
           pi.instance_code                            AS InstanceCode,
           pi.instance_name                            AS InstanceName,
           pio.obligation_id                           AS ObligationId,
           COALESCE(NULLIF(LTRIM(RTRIM(pio.obligation_name)), N''),
                    NULLIF(LTRIM(RTRIM(o.obligation_name)), N''),
                    LEFT(o.obligation_text, 120))      AS ObligationName,
           pub.PublishedCount                          AS PublishedCount,
           ISNULL(cr.CreatableTypes, 0)                AS CreatableTypes,
           (SELECT COUNT(*)
              FROM grac_practice.practice_instance_evidence pie
             WHERE pie.practice_instance_id = pio.practice_instance_id
               AND pie.source_obligation_id = pio.obligation_id
               AND pie.status = N'Active')             AS ActiveRows,
           (SELECT COUNT(*)
              FROM grac_practice.practice_instance_evidence pie
             WHERE pie.practice_instance_id = pio.practice_instance_id
               AND pie.source_obligation_id = pio.obligation_id
               AND pie.status <> N'Active')            AS InactiveRows,
           (SELECT COUNT(*)
              FROM grac_practice.practice_instance_evidence pie
             WHERE pie.practice_instance_id = pio.practice_instance_id
               AND pie.source_obligation_id IS NOT NULL
               AND pie.source_obligation_id <> pio.obligation_id
               AND pie.status = N'Active')             AS RowsForOtherObligations,
           (SELECT COUNT(*)
              FROM grac_practice.practice_instance_evidence pie
             WHERE pie.practice_instance_id = pio.practice_instance_id
               AND pie.source_obligation_id IS NULL
               AND pie.status = N'Active')             AS UnattachedRowsOnInstance,
           pio.entered_dt                              AS AdoptedOn,
           pio.entered_by                              AS AdoptedBy
    FROM   grac_practice.practice_instance_obligation pio
    JOIN   grac_practice.practice_instance pi
           ON pi.practice_instance_id = pio.practice_instance_id
    JOIN   published pub
           ON pub.obligation_id = pio.obligation_id
    LEFT   JOIN creatable cr
           ON cr.obligation_id = pio.obligation_id
    LEFT   JOIN GRAC_New.requirement_obligation o
           ON o.obligation_id = pio.obligation_id
    WHERE  pio.status = N'Active'
      AND  pub.PublishedCount > 0
)
SELECT PracticeInstanceId,
       InstanceCode,
       InstanceName,
       ObligationId,
       ObligationName,
       PublishedCount,
       CreatableTypes,
       ActiveRows,
       InactiveRows,
       RowsForOtherObligations,
       UnattachedRowsOnInstance,
       CASE
           WHEN CreatableTypes = 0
                THEN 'CATALOGUE -- no published type is creatable (already ruled out globally)'
           WHEN InactiveRows > 0
                THEN 'ROWS EXIST BUT ARE NOT ACTIVE -- status <> Active, so the card hides them'
           WHEN UnattachedRowsOnInstance > 0
                THEN 'UNATTACHED ROWS ON THIS INSTANCE -- source_obligation_id IS NULL; they may belong here'
           ELSE 'NEVER CREATED -- adoption did not insert them; press Save obligations on this instance'
       END                                         AS Diagnosis,
       AdoptedOn,
       AdoptedBy
FROM   candidates
WHERE  ActiveRows = 0
ORDER  BY InstanceCode, ObligationName;

PRINT '';
PRINT '===== 2. Same picture for ONE instance, including the healthy rows =====';
PRINT '      Set @practice_instance_id from section 1 to compare an';
PRINT '      obligation that works against one that does not.';
DECLARE @practice_instance_id BIGINT = NULL;   -- <<< optional

IF @practice_instance_id IS NULL
    SELECT 'Optional. Pick a PracticeInstanceId from section 1 to drill in.' AS Note;
ELSE
    SELECT pio.obligation_id                                  AS ObligationId,
           COALESCE(NULLIF(LTRIM(RTRIM(pio.obligation_name)), N''),
                    LEFT(o.obligation_text, 120))             AS ObligationName,
           (SELECT COUNT(DISTINCT roe.evidence_type_id)
              FROM GRAC_New.requirement_obligation_evidence roe
             WHERE roe.obligation_id = pio.obligation_id
               AND roe.evidence_type_id IS NOT NULL)          AS PublishedCount,
           (SELECT COUNT(*) FROM grac_practice.practice_instance_evidence pie
             WHERE pie.practice_instance_id = @practice_instance_id
               AND pie.source_obligation_id = pio.obligation_id
               AND pie.status = N'Active')                    AS ActiveRows,
           pio.status                                         AS AdoptionStatus,
           pio.entered_dt                                     AS AdoptedOn
    FROM   grac_practice.practice_instance_obligation pio
    LEFT   JOIN GRAC_New.requirement_obligation o
           ON o.obligation_id = pio.obligation_id
    WHERE  pio.practice_instance_id = @practice_instance_id
    ORDER  BY ObligationName;

PRINT '';
PRINT '===== 3. Every evidence row on that instance, however attributed =====';
IF @practice_instance_id IS NULL
    SELECT 'Optional. Same parameter as section 2.' AS Note;
ELSE
    -- The primary key is evidence_id (001_practice_management_schema.sql
    -- line 541), not practice_instance_evidence_id.
    SELECT pie.evidence_id                        AS RowId,
           pie.evidence_type_id                   AS PracticeEvidenceTypeId,
           pet.evidence_type_name                 AS EvidenceType,
           pie.source_obligation_id               AS SourceObligationId,
           CASE WHEN pie.source_obligation_id IS NULL
                THEN 'UNATTACHED -- invisible on every obligation card'
                ELSE 'Attached' END               AS Attribution,
           pie.status                             AS RowStatus,
           pie.entered_by,
           pie.entered_dt
    FROM   grac_practice.practice_instance_evidence pie
    LEFT   JOIN grac_practice.evidence_type_master pet
           ON pet.evidence_type_id = pie.evidence_type_id
    WHERE  pie.practice_instance_id = @practice_instance_id
    ORDER  BY pie.source_obligation_id, pet.evidence_type_name;
GO
