-- =====================================================================
-- 256 sp_task_centre_source_counts
--
-- 255 gave Gap Centre a Source filter whose options carry a count each
-- ("Assurance (12)"), filled by sp_gap_centre_source_counts. Task
-- Centre's Source filter shipped in the same change as a hardcoded
-- <select> with no counts, so the two Centres looked different for no
-- reason. Sir asked for them to match.
--
-- VOCABULARY. Exactly ck_pm_practice_task_source_type as widened by
-- migration 215:
--
--     Gap / Exception / Risk / RiskRegister /
--     ContinuousAssurance / EventAssurance / Custom
--
-- Returned in full including zero counts, for the same reason 255 does
-- it: an operator who filters to Event Assurance and sees "(0)" has
-- learned something; one who cannot find it in the list has not.
--
-- COUNTS WHAT THE LIST SHOWS. sp_task_list applies no status filter by
-- default and Task Centre does not pass one, so this counts every row
-- rather than open ones only. The badge and the grid must never disagree
-- -- that is the rule 247 settled for the Gaps badge and 253 for the
-- Custom tab.
--
-- Parent rows only (parent_task_id IS NULL), matching sp_task_list's
-- default: 194 creates decomposed children as separate practice_task
-- rows, and counting them would inflate every source the moment somebody
-- split a task.
--
-- UNSOURCED ROWS. source_type_code is nullable (192 allows it, and
-- pre-192 rows carry NULL). Those are counted separately as
-- UnsourcedCount on a second result set rather than hidden, so the
-- dropdown's numbers can be reconciled against the grid total. There is
-- no way to FILTER to them -- sp_task_list's predicate is
-- "@source_type_code IS NULL OR v.source_type_code = @source_type_code",
-- which cannot express "source is null" -- so this is a reporting value,
-- not a filter option.
--
-- SAFE TO RE-RUN. Requires 037 (practice_task), 192/215 (source_type_code).
-- ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

DECLARE @ok BIT = 1;
IF SCHEMA_ID('grac_practice') IS NULL
BEGIN PRINT 'ABORT (256): schema grac_practice missing.'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.practice_task','U') IS NULL
BEGIN PRINT 'ABORT (256): practice_task missing (run 037 first).'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.practice_task','U') IS NOT NULL
   AND COL_LENGTH('grac_practice.practice_task','source_type_code') IS NULL
BEGIN PRINT 'ABORT (256): practice_task.source_type_code missing (run 192 first).'; SET @ok = 0; END
IF @ok = 0
BEGIN
    RAISERROR('256_task_centre_source_counts: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_task_centre_source_counts
    @organization_id BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    -- Result set 1 -- the filterable vocabulary, in dropdown order.
    ;WITH vocab(SourceTypeCode, DisplayOrder) AS (
        SELECT N'Gap',                 1 UNION ALL
        SELECT N'Exception',           2 UNION ALL
        SELECT N'Risk',                3 UNION ALL
        SELECT N'RiskRegister',        4 UNION ALL
        SELECT N'ContinuousAssurance', 5 UNION ALL
        SELECT N'EventAssurance',      6 UNION ALL
        SELECT N'Custom',              7
    )
    SELECT v.SourceTypeCode,
           v.DisplayOrder,
           (SELECT COUNT_BIG(*)
              FROM grac_practice.practice_task t
             WHERE (@organization_id IS NULL OR t.organization_id = @organization_id)
               AND t.parent_task_id IS NULL
               AND t.source_type_code = v.SourceTypeCode) AS TaskCount
    FROM   vocab v
    ORDER  BY v.DisplayOrder;

    -- Result set 2 -- totals, so the dropdown can label "All sources"
    -- and the caller can see how many rows carry no source at all.
    SELECT
        (SELECT COUNT_BIG(*)
           FROM grac_practice.practice_task t
          WHERE (@organization_id IS NULL OR t.organization_id = @organization_id)
            AND t.parent_task_id IS NULL) AS TotalCount,
        (SELECT COUNT_BIG(*)
           FROM grac_practice.practice_task t
          WHERE (@organization_id IS NULL OR t.organization_id = @organization_id)
            AND t.parent_task_id IS NULL
            AND t.source_type_code IS NULL) AS UnsourcedCount;
END
GO
PRINT '256: sp_task_centre_source_counts created.';
GO

-- =====================================================================
-- Verification
-- =====================================================================
PRINT '=== 256 verification ===';

DECLARE @p NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_task_centre_source_counts','P'));

SELECT '256-a procedure exists' AS Check_,
       CASE WHEN @p IS NOT NULL THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '256-b carries the full 215 vocabulary',
       CASE WHEN @p LIKE '%RiskRegister%'
             AND @p LIKE '%ContinuousAssurance%'
             AND @p LIKE '%EventAssurance%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '256-c counts parent rows only (matches sp_task_list default)',
       CASE WHEN @p LIKE '%parent_task_id IS NULL%' THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '256-d reports unsourced rows rather than hiding them',
       CASE WHEN @p LIKE '%UnsourcedCount%' THEN 'PASS' ELSE 'FAIL' END;

PRINT '';
PRINT '--- Reconciliation: per-source counts + unsourced must equal the total ---';
PRINT 'Whole-tenant scope. A mismatch means a source_type_code value exists';
PRINT 'in the data that is not in ck_pm_practice_task_source_type.';

SELECT
    (SELECT COUNT_BIG(*) FROM grac_practice.practice_task
      WHERE parent_task_id IS NULL)                       AS TotalParentRows,
    (SELECT COUNT_BIG(*) FROM grac_practice.practice_task
      WHERE parent_task_id IS NULL
        AND source_type_code IS NULL)                     AS Unsourced,
    (SELECT COUNT_BIG(*) FROM grac_practice.practice_task
      WHERE parent_task_id IS NULL
        AND source_type_code IN (N'Gap', N'Exception', N'Risk', N'RiskRegister',
                                 N'ContinuousAssurance', N'EventAssurance', N'Custom'))
                                                          AS InVocabulary,
    (SELECT COUNT_BIG(*) FROM grac_practice.practice_task
      WHERE parent_task_id IS NULL
        AND source_type_code IS NOT NULL
        AND source_type_code NOT IN (N'Gap', N'Exception', N'Risk', N'RiskRegister',
                                     N'ContinuousAssurance', N'EventAssurance', N'Custom'))
                                                          AS OutsideVocabulary;

PRINT '';
PRINT '256 complete. Task Centre Source filter can show counts like Gap Centre.';
GO

SET NOEXEC OFF;
GO
