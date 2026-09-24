-- =====================================================================
-- 307 Practice-level obligations -- ROLLBACK
--
-- Removes what 307 added, in dependency order:
--   1. the fanned-out COPIES on the instances (they are the only rows
--      that carry source_practice_obligation_id, so they can be told
--      apart from every other obligation row with certainty)
--   2. the three procedures
--   3. the filtered index, the foreign key and the marker column
--   4. the practice_obligation table
--
-- WHY THE COPIES ARE DELETED AND NOT RETIRED
-- ------------------------------------------
-- The column that says a row IS a copy is about to be dropped. A retired
-- copy left behind would become an ordinary organisation-defined
-- obligation with no way to tell where it came from -- worse than gone.
--
-- EVIDENCE PRODUCED AGAINST A COPY IS KEPT
-- ----------------------------------------
-- Evidence rows point at the copy through
-- source_practice_instance_obligation_id. Deleting a copy with a filled-in
-- evidence row underneath it would throw work away, so those rows are
-- DETACHED (the link set to NULL) rather than deleted, and the copy whose
-- evidence has been filled in is retired instead of deleted. The section
-- reports both counts.
--
-- Set @Force = 1 to delete such copies anyway. Off by default.
--
-- Re-runnable: yes.
-- ASCII-only on purpose (see the forward script header).
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET NOEXEC OFF;
GO

DECLARE @Force BIT = 0;   -- 1 = delete copies that have filled-in evidence too

IF COL_LENGTH('grac_practice.practice_instance_obligation','source_practice_obligation_id') IS NULL
BEGIN
    PRINT '307 rollback: source_practice_obligation_id already gone -- nothing from 307 to remove.';
    SET NOEXEC ON;
END
GO

DECLARE @Force BIT = 0;   -- keep in step with the value above

-- ---------------------------------------------------------------------
-- 1a. Evidence that belongs to a copy somebody has worked on. Detach it
--     and retire the copy; the work stays readable on the instance.
-- ---------------------------------------------------------------------
DECLARE @worked TABLE (practice_instance_obligation_id BIGINT PRIMARY KEY);

INSERT @worked (practice_instance_obligation_id)
SELECT DISTINCT pio.practice_instance_obligation_id
FROM   grac_practice.practice_instance_obligation pio
JOIN   grac_practice.practice_instance_evidence pie
       ON pie.source_practice_instance_obligation_id = pio.practice_instance_obligation_id
WHERE  pio.source_practice_obligation_id IS NOT NULL
  AND (NULLIF(LTRIM(RTRIM(ISNULL(pie.evidence_location, N''))), N'') IS NOT NULL
       OR NULLIF(LTRIM(RTRIM(ISNULL(pie.evidence_locator, N''))), N'') IS NOT NULL
       OR NULLIF(LTRIM(RTRIM(ISNULL(pie.evidence_owner,   N''))), N'') IS NOT NULL);

IF @Force = 1 DELETE FROM @worked;

SELECT 'Copies with filled-in evidence (kept unless @Force = 1)' AS Check_,
       COUNT(*) AS Count_ FROM @worked;

-- Evidence created for a copy that IS going away: unlink it rather than
-- delete it. An empty evidence row is worth nothing, but the row also
-- costs nothing to keep, and deleting rows nobody asked us to delete is
-- not a rollback's job.
UPDATE pie
   SET source_practice_instance_obligation_id = NULL,
       updated_by = N'rollback-307',
       updated_dt = SYSUTCDATETIME()
FROM   grac_practice.practice_instance_evidence pie
JOIN   grac_practice.practice_instance_obligation pio
       ON pio.practice_instance_obligation_id = pie.source_practice_instance_obligation_id
WHERE  pio.source_practice_obligation_id IS NOT NULL
  AND  NOT EXISTS (SELECT 1 FROM @worked w
                    WHERE w.practice_instance_obligation_id = pio.practice_instance_obligation_id);

PRINT '307 rollback: evidence rows detached = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));

UPDATE pio
   SET status     = N'Retired',
       updated_by = N'rollback-307',
       updated_dt = SYSUTCDATETIME()
FROM   grac_practice.practice_instance_obligation pio
JOIN   @worked w ON w.practice_instance_obligation_id = pio.practice_instance_obligation_id
WHERE  pio.status = N'Active';

PRINT '307 rollback: copies retired (evidence in use) = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));

-- ---------------------------------------------------------------------
-- 1b. Every other copy goes.
-- ---------------------------------------------------------------------
DELETE pio
FROM   grac_practice.practice_instance_obligation pio
WHERE  pio.source_practice_obligation_id IS NOT NULL
  AND  NOT EXISTS (SELECT 1 FROM @worked w
                    WHERE w.practice_instance_obligation_id = pio.practice_instance_obligation_id);

PRINT '307 rollback: copies deleted = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

-- ---------------------------------------------------------------------
-- 2. Procedures
-- ---------------------------------------------------------------------
IF OBJECT_ID('grac_practice.sp_practice_obligation_list','P') IS NOT NULL
BEGIN
    DROP PROCEDURE grac_practice.sp_practice_obligation_list;
    PRINT '307 rollback: sp_practice_obligation_list dropped.';
END
GO

IF OBJECT_ID('grac_practice.sp_practice_obligation_save','P') IS NOT NULL
BEGIN
    DROP PROCEDURE grac_practice.sp_practice_obligation_save;
    PRINT '307 rollback: sp_practice_obligation_save dropped.';
END
GO

IF OBJECT_ID('grac_practice.sp_practice_obligation_fan_out','P') IS NOT NULL
BEGIN
    DROP PROCEDURE grac_practice.sp_practice_obligation_fan_out;
    PRINT '307 rollback: sp_practice_obligation_fan_out dropped.';
END
GO

-- ---------------------------------------------------------------------
-- 3. Index, foreign key, column -- in that order, or the drops refuse.
-- ---------------------------------------------------------------------
IF EXISTS (SELECT 1 FROM sys.indexes
            WHERE name = 'ux_pm_pio_practice_obligation'
              AND object_id = OBJECT_ID('grac_practice.practice_instance_obligation'))
BEGIN
    DROP INDEX ux_pm_pio_practice_obligation ON grac_practice.practice_instance_obligation;
    PRINT '307 rollback: ux_pm_pio_practice_obligation dropped.';
END
GO

IF EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_pm_pio_practice_obligation')
BEGIN
    ALTER TABLE grac_practice.practice_instance_obligation
        DROP CONSTRAINT fk_pm_pio_practice_obligation;
    PRINT '307 rollback: fk_pm_pio_practice_obligation dropped.';
END
GO

IF COL_LENGTH('grac_practice.practice_instance_obligation','source_practice_obligation_id') IS NOT NULL
BEGIN
    ALTER TABLE grac_practice.practice_instance_obligation
        DROP COLUMN source_practice_obligation_id;
    PRINT '307 rollback: source_practice_obligation_id dropped.';
END
GO

-- ---------------------------------------------------------------------
-- 4. The definition table
-- ---------------------------------------------------------------------
IF OBJECT_ID('grac_practice.practice_obligation','U') IS NOT NULL
BEGIN
    DROP TABLE grac_practice.practice_obligation;
    PRINT '307 rollback: grac_practice.practice_obligation dropped.';
END
GO

-- ---------------------------------------------------------------------
-- Verification
-- ---------------------------------------------------------------------
SELECT '307 rollback-a table gone' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.practice_obligation','U') IS NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '307 rollback-b marker column gone',
       CASE WHEN COL_LENGTH('grac_practice.practice_instance_obligation','source_practice_obligation_id')
                 IS NULL THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '307 rollback-c procedures gone',
       CASE WHEN OBJECT_ID('grac_practice.sp_practice_obligation_save','P') IS NULL
             AND OBJECT_ID('grac_practice.sp_practice_obligation_fan_out','P') IS NULL
             AND OBJECT_ID('grac_practice.sp_practice_obligation_list','P') IS NULL
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
-- 227's own rows must be exactly as they were.
SELECT '307 rollback-d instance-custom obligations intact',
       CASE WHEN NOT EXISTS (SELECT 1 FROM grac_practice.practice_instance_obligation
                              WHERE updated_by = N'rollback-307'
                                AND obligation_id IS NULL)
            THEN 'PASS' ELSE 'REVIEW' END;

PRINT '307 rollback complete.';
GO

SET NOEXEC OFF;
GO
