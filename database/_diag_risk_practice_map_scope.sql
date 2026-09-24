-- =====================================================================
-- DIAGNOSTIC -- "Map Practice says already selected on a new risk"
--
-- READ-ONLY. No CREATE, no ALTER, no INSERT, no UPDATE, no DELETE.
-- Safe to run on production. Nothing here changes anything.
--
-- WHY THIS FILE EXISTS
--   A static read of the code says the exclusion is per risk at every
--   layer:
--
--     * risk_practice_map is UNIQUE(risk_register_id, practice_id), and
--       the "one Primary per risk" index is filtered on
--       risk_register_id -- so the SCHEMA cannot express a global claim.
--     * sp_risk_practice_map's duplicate guard is keyed on the PAIR.
--     * sp_risk_mapping_get lists practices
--       `WHERE pm.risk_register_id = @risk_register_id`.
--     * sp_practice_picker_practices has NO risk parameter at all -- it
--       excludes only the ids the caller hands it.
--     * the caller hands it st.mappedPracticeIds, which is that one
--       risk's /mapping response.
--
--   So either the data disagrees with that reading, or the practice
--   being hidden really is on the risk in question. Section 3 answers
--   which, and section 4 names the most likely innocent explanation.
--
-- HOW TO USE
--   Set @RiskId to the NEW risk that wrongly showed "already selected",
--   and @PracticeId to the practice it would not offer. Both optional:
--   leave them NULL for a whole-organisation picture.
-- =====================================================================
SET NOCOUNT ON;

DECLARE @RiskId     BIGINT = NULL;   -- <<< the risk you were mapping
DECLARE @PracticeId BIGINT = NULL;   -- <<< the practice it would not offer

PRINT '=== 1. Is the uniqueness per risk, or global? ===============';
-- A global claim would show as a unique constraint on practice_id ALONE.
SELECT kc.name                     AS ConstraintName,
       kc.type_desc                AS Kind,
       STUFF((SELECT N', ' + c2.name
                FROM sys.index_columns ic2
                JOIN sys.columns c2
                  ON c2.object_id = ic2.object_id AND c2.column_id = ic2.column_id
               WHERE ic2.object_id = i.object_id AND ic2.index_id = i.index_id
               ORDER BY ic2.key_ordinal
                 FOR XML PATH('')), 1, 2, N'') AS KeyColumns,
       i.filter_definition         AS FilterDefinition,
       CASE WHEN EXISTS (SELECT 1 FROM sys.index_columns ic3
                          WHERE ic3.object_id = i.object_id
                            AND ic3.index_id  = i.index_id
                            AND COL_NAME(ic3.object_id, ic3.column_id) = 'risk_register_id')
            THEN 'PER RISK' ELSE 'CHECK THIS -- no risk_register_id in the key' END AS Verdict
  FROM sys.indexes i
  LEFT JOIN sys.key_constraints kc ON kc.parent_object_id = i.object_id AND kc.unique_index_id = i.index_id
 WHERE i.object_id = OBJECT_ID('grac_practice.risk_practice_map')
   AND i.is_unique = 1;

PRINT '';
PRINT '=== 2. Every risk this practice is mapped to ================';
-- If the practice is on OTHER risks but not on @RiskId, and the picker
-- still hid it, the bug is real and this is the evidence.
SELECT pm.risk_register_id      AS RiskId,
       r.risk_number            AS RiskNumber,
       r.risk_title             AS RiskTitle,
       pm.practice_id           AS PracticeId,
       pm.practice_name         AS PracticeName,
       pm.map_source_code       AS MapSource,
       pm.mapped_dt             AS MappedOn,
       CASE WHEN @RiskId IS NOT NULL AND pm.risk_register_id = @RiskId
            THEN '<-- THIS RISK' ELSE '' END AS Note
  FROM grac_practice.risk_practice_map pm
  JOIN grac_practice.risk_register r ON r.risk_register_id = pm.risk_register_id
 WHERE (@PracticeId IS NULL OR pm.practice_id = @PracticeId)
 ORDER BY pm.practice_id, pm.risk_register_id;

PRINT '';
PRINT '=== 3. THE ANSWER: what the picker is told to exclude =======';
-- This is exactly st.mappedPracticeIds for @RiskId: the practice list
-- sp_risk_mapping_get returns, which is the only thing the picker hides.
IF @RiskId IS NULL
    PRINT '   (set @RiskId to run this section)';
ELSE
BEGIN
    SELECT pm.practice_id     AS ExcludedPracticeId,
           pm.practice_name   AS PracticeName,
           pm.map_source_code AS MapSource,
           CASE WHEN pm.map_source_code = N'Primary'
                THEN 'DERIVED from risk_register.linked_practice_id -- see section 4'
                ELSE 'mapped by a person on this risk' END AS Why
      FROM grac_practice.risk_practice_map pm
     WHERE pm.risk_register_id = @RiskId
     ORDER BY pm.map_source_code, pm.practice_id;

    IF @PracticeId IS NOT NULL
        SELECT CASE WHEN EXISTS (SELECT 1 FROM grac_practice.risk_practice_map
                                  WHERE risk_register_id = @RiskId
                                    AND practice_id      = @PracticeId)
                    THEN 'EXPECTED -- that practice IS on this risk, so hiding it is correct.'
                    ELSE 'BUG CONFIRMED -- that practice is NOT on this risk, so nothing should hide it.'
               END AS Verdict;
END

PRINT '';
PRINT '=== 4. The innocent explanation, checked ===================';
-- sp_risk_mapping_sync_primary turns risk_register.linked_practice_id
-- into a Primary map row on the first /mapping read. So a risk RAISED
-- FROM a practice arrives with that practice already in its own scope --
-- correctly -- and the picker will not offer it again. That is the one
-- case that looks like a global exclusion and is not.
SELECT r.risk_register_id    AS RiskId,
       r.risk_number         AS RiskNumber,
       r.linked_practice_id  AS LinkedPracticeId,
       p.practice_name       AS LinkedPracticeName,
       CASE WHEN EXISTS (SELECT 1 FROM grac_practice.risk_practice_map pm
                          WHERE pm.risk_register_id = r.risk_register_id
                            AND pm.practice_id      = r.linked_practice_id)
            THEN 'yes -- and it is therefore hidden in the picker, correctly'
            ELSE 'not yet -- derived on the first scope-panel read'
       END                   AS PrimaryRowDerived
  FROM grac_practice.risk_register r
  LEFT JOIN grac_practice.practice p ON p.practice_id = r.linked_practice_id
 WHERE (@RiskId IS NULL OR r.risk_register_id = @RiskId)
   AND r.linked_practice_id IS NOT NULL
 ORDER BY r.risk_register_id;

PRINT '';
PRINT '=== 5. Does any deployed procedure check the map globally? ==';
-- A global check would reference risk_practice_map WITHOUT comparing
-- risk_register_id. Nothing should come back here.
SELECT o.name AS ProcedureName,
       'references risk_practice_map but never compares risk_register_id' AS Concern
  FROM sys.sql_modules m
  JOIN sys.objects o ON o.object_id = m.object_id
 WHERE m.definition LIKE '%risk_practice_map%'
   AND m.definition NOT LIKE '%risk_register_id%'
 ORDER BY o.name;

PRINT '';
PRINT 'Diagnostic complete. Section 3 is the one that settles it:';
PRINT '  "EXPECTED" -> the practice really is on that risk (usually the';
PRINT '                derived Primary row explained in section 4).';
PRINT '  "BUG CONFIRMED" -> send section 2 and 3 output back.';
