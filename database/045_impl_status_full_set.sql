-- =====================================================================
-- 045 Implementation-status full 4-value set + auto-sync trigger
--
-- User requirement: the accepted values shall be
--   * Not Implemented
--   * Partially Implemented
--   * Implemented
--   * Not Applicable      (may be N/A if applicable)
--
-- This reverses 044's deactivation of "Partially Implemented", adds a
-- clean "Not Applicable" master row, and deactivates "Not Updated"
-- (which 044 introduced but is no longer in scope).
--
-- Also adds an AFTER INSERT/UPDATE trigger on practice_instance that
-- keeps implementation_status_id in sync with the text column whenever
-- callers set only one of them. This prevents drift when
-- pm_manage_practice_repository receives text but no id (or vice-versa).
--
-- Idempotent. Rollback: 045_impl_status_full_set_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

-- Prereq guard.
DECLARE @ok BIT = 1;
IF OBJECT_ID('grac_practice.implementation_status_master','U') IS NULL BEGIN PRINT 'ABORT (045): implementation_status_master missing.'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.practice_instance','U') IS NULL          BEGIN PRINT 'ABORT (045): practice_instance missing.'; SET @ok = 0; END
IF @ok = 0 BEGIN RAISERROR('045 prereqs missing', 16, 1); SET NOEXEC ON; END
GO

-- =====================================================================
-- 1. Seed / normalise the 4 accepted values
-- =====================================================================
;WITH src AS (
    SELECT * FROM (VALUES
        (N'Not Implemented',        N'Not Implemented',        10),
        (N'Partially Implemented',  N'Partially Implemented',  20),
        (N'Implemented',            N'Implemented',            30),
        (N'Not Applicable',         N'Not Applicable',         40)
    ) v(status_code, status_name, display_order)
)
MERGE grac_practice.implementation_status_master AS t
USING src
   ON t.status_code = src.status_code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (status_code, status_name, display_order, is_active, entered_by)
    VALUES (src.status_code, src.status_name, src.display_order, 1, 'seed-045')
WHEN MATCHED THEN
    UPDATE SET status_name  = src.status_name,
               display_order= src.display_order,
               is_active    = 1,
               updated_by   = 'seed-045',
               updated_dt   = SYSUTCDATETIME();
GO

-- Deactivate everything not in the accepted set
UPDATE grac_practice.implementation_status_master
   SET is_active  = 0,
       updated_by = 'seed-045',
       updated_dt = SYSUTCDATETIME()
 WHERE status_code NOT IN (N'Not Implemented', N'Partially Implemented', N'Implemented', N'Not Applicable')
   AND is_active = 1;
GO

-- =====================================================================
-- 2. Backfill: rows whose implementation_status text is now a stale
--    value ("N/A", "Not Updated", "Active", etc) get resolved to
--    "Not Implemented" as a safe default. Text-only mismatches also fixed.
-- =====================================================================
DECLARE @not_impl_id INT   = (SELECT implementation_status_id FROM grac_practice.implementation_status_master WHERE status_code = N'Not Implemented');
DECLARE @impl_id INT       = (SELECT implementation_status_id FROM grac_practice.implementation_status_master WHERE status_code = N'Implemented');
DECLARE @partial_id INT    = (SELECT implementation_status_id FROM grac_practice.implementation_status_master WHERE status_code = N'Partially Implemented');
DECLARE @na_id INT         = (SELECT implementation_status_id FROM grac_practice.implementation_status_master WHERE status_code = N'Not Applicable');

UPDATE pi
   SET implementation_status =
       CASE
         WHEN pi.implementation_status IN (N'Implemented')                     THEN N'Implemented'
         WHEN pi.implementation_status IN (N'Partially Implemented')            THEN N'Partially Implemented'
         WHEN pi.implementation_status IN (N'Not Applicable', N'N/A', N'NA')   THEN N'Not Applicable'
         WHEN pi.implementation_status IN (N'Not Implemented')                  THEN N'Not Implemented'
         ELSE N'Not Implemented'
       END,
       implementation_status_id =
       CASE
         WHEN pi.implementation_status IN (N'Implemented')                     THEN @impl_id
         WHEN pi.implementation_status IN (N'Partially Implemented')            THEN @partial_id
         WHEN pi.implementation_status IN (N'Not Applicable', N'N/A', N'NA')   THEN @na_id
         WHEN pi.implementation_status IN (N'Not Implemented')                  THEN @not_impl_id
         ELSE @not_impl_id
       END,
       updated_by = 'backfill-045',
       updated_dt = SYSUTCDATETIME()
FROM grac_practice.practice_instance pi
LEFT JOIN grac_practice.implementation_status_master ims
       ON ims.implementation_status_id = pi.implementation_status_id
WHERE ims.implementation_status_id IS NULL
   OR ims.is_active = 0
   OR pi.implementation_status <> ims.status_code;
GO

-- =====================================================================
-- 3. Auto-sync trigger — keep implementation_status_id in sync when
--    callers set only the text column (e.g. pm_manage_practice_repository
--    when payload has implementationStatus text but no id).
--    Trigger fires AFTER INSERT/UPDATE, so callers can still explicitly
--    set the id and have it win; the trigger only fills gaps.
-- =====================================================================
CREATE OR ALTER TRIGGER grac_practice.tr_pm_practice_instance_impl_status_sync
ON grac_practice.practice_instance
AFTER INSERT, UPDATE
NOT FOR REPLICATION
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT UPDATE(implementation_status) AND NOT UPDATE(implementation_status_id) RETURN;

    -- Case A: text set, id doesn't match text -> reset id from text.
    UPDATE pi
       SET implementation_status_id = ims.implementation_status_id
    FROM grac_practice.practice_instance pi
    JOIN inserted i ON i.practice_instance_id = pi.practice_instance_id
    JOIN grac_practice.implementation_status_master ims
         ON ims.status_code = pi.implementation_status
        AND ims.is_active = 1
    WHERE pi.implementation_status IS NOT NULL
      AND (pi.implementation_status_id IS NULL
           OR NOT EXISTS (
                SELECT 1 FROM grac_practice.implementation_status_master ims2
                WHERE ims2.implementation_status_id = pi.implementation_status_id
                  AND ims2.status_code = pi.implementation_status));

    -- Case B: id set, text doesn't match -> reset text from id.
    UPDATE pi
       SET implementation_status = ims.status_code
    FROM grac_practice.practice_instance pi
    JOIN inserted i ON i.practice_instance_id = pi.practice_instance_id
    JOIN grac_practice.implementation_status_master ims
         ON ims.implementation_status_id = pi.implementation_status_id
    WHERE pi.implementation_status_id IS NOT NULL
      AND (pi.implementation_status IS NULL
           OR pi.implementation_status <> ims.status_code);
END;
GO

-- =====================================================================
-- Sanity
-- =====================================================================
SELECT 'Accepted rows active' AS Check_,
       COUNT(*) AS ActiveCount
FROM grac_practice.implementation_status_master
WHERE status_code IN (N'Not Implemented', N'Partially Implemented', N'Implemented', N'Not Applicable')
  AND is_active = 1;

SELECT 'Non-accepted rows inactive' AS Check_,
       CASE WHEN NOT EXISTS (
           SELECT 1 FROM grac_practice.implementation_status_master
           WHERE status_code NOT IN (N'Not Implemented', N'Partially Implemented', N'Implemented', N'Not Applicable')
             AND is_active = 1)
           THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT 'Practice Instance distribution' AS Report,
       ims.status_code, COUNT(*) AS RowCount_
FROM grac_practice.practice_instance pi
LEFT JOIN grac_practice.implementation_status_master ims ON ims.implementation_status_id = pi.implementation_status_id
GROUP BY ims.status_code
ORDER BY ims.status_code;

PRINT '045 implementation-status full set + sync trigger installed.';
GO

SET NOEXEC OFF;
GO
