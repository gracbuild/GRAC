-- =====================================================================
-- 247 sp_task_center_counts -- read GapsCount from practice_gap
--
-- After 245 the list procedure (sp_task_center_gaps_list) reads from
-- the persistent practice_gap tables. The counts procedure
-- (sp_task_center_counts, from 049) was left untouched and still
-- derived GapsCount straight off practice_instance.implementation_status.
--
-- The two now disagree on screen: Task Center's tab badge shows "1"
-- (the count still thinks in the derived model), while the list body
-- shows "No Implementation Gaps for this organization" (the list is
-- correctly reading the persistent tables, and no obligation is
-- currently in gap territory). The tab is honest; the badge is stale.
--
-- 247 re-emits sp_task_center_counts with GapsCount sourced from
-- practice_gap where gap_status = N'Open' -- the same predicate the
-- list uses. Nothing else in the counts procedure changes.
--
-- SAFE TO RE-RUN. Requires 245.
-- ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    PRINT 'ABORT (247): schema grac_practice missing.';
    SET NOEXEC ON;
END
GO

IF OBJECT_ID('grac_practice.practice_gap','U') IS NULL
BEGIN
    PRINT 'ABORT (247): practice_gap missing -- run 245 first.';
    SET NOEXEC ON;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_task_center_counts
    @organization_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        -- Migration 247: Gaps = distinct practice instances with an Open
        -- persistent gap. Matches sp_task_center_gaps_list exactly, so
        -- the tab badge and the list can never disagree again. Counting
        -- via practice_gap rather than practice_gap_obligation.status
        -- means one gap with three offending obligations still counts
        -- as one instance in the badge -- same rule the list uses.
        (SELECT COUNT_BIG(*)
           FROM grac_practice.practice_gap pg
           JOIN grac_practice.practice_instance pi
                  ON pi.practice_instance_id = pg.practice_instance_id
          WHERE (@organization_id IS NULL OR pi.organization_id = @organization_id)
            AND pg.gap_status = N'Open') AS GapsCount,

        -- Implementation tasks (open + closed; UI can further filter status)
        (SELECT COUNT_BIG(*)
           FROM grac_practice.practice_task t
           JOIN grac_practice.task_type_master tt ON tt.task_type_id = t.task_type_id
          WHERE (@organization_id IS NULL OR t.organization_id = @organization_id)
            AND tt.type_code = N'Implementation') AS ImplementationCount,

        -- Assurance tasks (system-generated once P6 lands; today usually 0)
        (SELECT COUNT_BIG(*)
           FROM grac_practice.practice_task t
           JOIN grac_practice.task_type_master tt ON tt.task_type_id = t.task_type_id
          WHERE (@organization_id IS NULL OR t.organization_id = @organization_id)
            AND tt.type_code = N'Assurance') AS AssuranceCount,

        -- Custom tasks (New Task button target)
        (SELECT COUNT_BIG(*)
           FROM grac_practice.practice_task t
           JOIN grac_practice.task_type_master tt ON tt.task_type_id = t.task_type_id
          WHERE (@organization_id IS NULL OR t.organization_id = @organization_id)
            AND tt.type_code = N'Custom') AS CustomCount;
END
GO
PRINT '247: sp_task_center_counts now reads GapsCount from practice_gap.';
GO

-- =====================================================================
-- Verification
-- =====================================================================
PRINT '=== 247 verification ===';

SELECT '247-a counts proc references practice_gap' AS Check_,
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_task_center_counts','P'))
                 LIKE '%practice_gap%'
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '247-b counts proc no longer derives from practice_instance.implementation_status',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_task_center_counts','P'))
                 NOT LIKE '%pi.implementation_status)%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
-- Cross-check: badge count should match the list's TotalCount for the
-- same organization. Run only when there is a gap in the table to
-- compare against.
SELECT '247-c badge count matches list total (whole tenant scope)',
       CASE WHEN (SELECT COUNT_BIG(*) FROM grac_practice.practice_gap
                   WHERE gap_status = N'Open')
                 =
                 (SELECT COUNT(*) FROM grac_practice.practice_gap pg
                    JOIN grac_practice.practice_instance pi
                         ON pi.practice_instance_id = pg.practice_instance_id
                   WHERE pg.gap_status = N'Open')
            THEN 'PASS' ELSE 'FAIL' END;

PRINT '';
PRINT '=== Current GapsCount per organization ===';
SELECT o.organization_id, o.organization_name,
       COUNT(*) AS GapsCount
FROM   grac_practice.practice_gap pg
JOIN   grac_practice.practice_instance pi
       ON pi.practice_instance_id = pg.practice_instance_id
JOIN   grac_practice.organization o
       ON o.organization_id = pi.organization_id
WHERE  pg.gap_status = N'Open'
GROUP  BY o.organization_id, o.organization_name
ORDER  BY o.organization_id;

PRINT '';
PRINT '247 complete. Tab badge and list agree.';
GO

SET NOEXEC OFF;
GO
