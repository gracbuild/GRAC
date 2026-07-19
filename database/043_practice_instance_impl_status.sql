-- =====================================================================
-- 043 Practice-Instance implementation-status extension  (Q13 resolution)
--
-- HISTORY:
--   v1 assumed practice_instance.implementation_status_id did not exist
--   and created a fresh FK named fk_pm_practice_instance_impl_status.
--   That was WRONG — the column was already added in migration 002 and
--   made NOT NULL with FK fk_pm_practice_instance_implementation_status
--   in migration 008. v2 (this file) detects and reuses the pre-existing
--   column + FK, only seeding master data + adding a supporting index.
--
-- Scope now:
--   1. Seed the three new status values 'Not Implemented',
--      'Partially Implemented', 'N/A'  (idempotent MERGE)
--   2. Normalise 'Implemented' display_order
--   3. Add a supporting index (guarded)
--   4. Backfill only rows whose implementation_status_id IS NULL
--      (defensive — the column is NOT NULL in normal databases; this
--      is a safety net for restore-from-partial-backup scenarios)
--   5. Detect and DROP any legacy duplicate FK named
--      fk_pm_practice_instance_impl_status (created by v1 of this file);
--      always leave the canonical fk_pm_practice_instance_implementation_status
--      in place.
--
-- Rollback: 043_practice_instance_impl_status_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

-- Prerequisite guard.
DECLARE @prereqs_ok BIT = 1;

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    PRINT 'ABORT (043): schema grac_practice missing.';
    SET @prereqs_ok = 0;
END

IF OBJECT_ID('grac_practice.implementation_status_master','U') IS NULL
BEGIN
    PRINT 'ABORT (043): implementation_status_master missing.';
    SET @prereqs_ok = 0;
END

IF OBJECT_ID('grac_practice.practice_instance','U') IS NULL
BEGIN
    PRINT 'ABORT (043): practice_instance missing.';
    SET @prereqs_ok = 0;
END

IF @prereqs_ok = 0
BEGIN
    RAISERROR('043 prerequisites missing — see PRINT above.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. Seed the three new status values (idempotent MERGE).
--    'Implemented' already exists (seeded by 03_Insert_Master_Data.sql).
-- =====================================================================
;WITH src AS (
    SELECT * FROM (VALUES
        (N'Not Implemented',        N'Not Implemented',       10),
        (N'Partially Implemented',  N'Partially Implemented', 20),
        (N'N/A',                    N'Not Applicable',        40)
    ) v(status_code, status_name, display_order)
)
MERGE grac_practice.implementation_status_master AS t
USING src
   ON t.status_code = src.status_code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (status_code, status_name, display_order, is_active, entered_by)
    VALUES (src.status_code, src.status_name, src.display_order, 1, 'seed-043')
WHEN MATCHED AND (t.status_name <> src.status_name OR t.display_order <> src.display_order) THEN
    UPDATE SET status_name  = src.status_name,
               display_order= src.display_order,
               is_active    = 1,
               updated_by   = 'seed-043',
               updated_dt   = SYSUTCDATETIME();
GO

-- 'Implemented' display_order harmonisation
UPDATE grac_practice.implementation_status_master
   SET display_order = 30,
       updated_by    = 'seed-043',
       updated_dt    = SYSUTCDATETIME()
 WHERE status_code = N'Implemented'
   AND display_order <> 30;
GO

-- =====================================================================
-- 2. Column / FK detection.
--    The column implementation_status_id was ALREADY added by migration
--    002 and made NOT NULL with FK fk_pm_practice_instance_implementation_status
--    by migration 008. We MUST NOT re-add it. We also must NOT create a
--    duplicate FK. Defensive:
--      * PRINT current state
--      * Refuse to add the column if it exists (skip silently)
--      * Refuse to add a second FK if any FK on this column already exists
-- =====================================================================
IF COL_LENGTH('grac_practice.practice_instance', 'implementation_status_id') IS NULL
BEGIN
    PRINT '043: adding implementation_status_id column (unexpected — should have been added by migration 002).';
    ALTER TABLE grac_practice.practice_instance ADD implementation_status_id INT NULL;
END
ELSE
BEGIN
    PRINT '043: implementation_status_id column already present. Skipping ADD.';
END
GO

-- Check for ANY existing FK on this column (regardless of name) before
-- attempting to add ours. If one exists, we piggy-back on it.
DECLARE @existing_fk_name NVARCHAR(200);
SELECT TOP 1 @existing_fk_name = fk.name
FROM sys.foreign_keys fk
JOIN sys.foreign_key_columns fkc ON fkc.constraint_object_id = fk.object_id
JOIN sys.columns c
    ON c.object_id = fkc.parent_object_id AND c.column_id = fkc.parent_column_id
WHERE fk.parent_object_id = OBJECT_ID('grac_practice.practice_instance')
  AND c.name = 'implementation_status_id';

IF @existing_fk_name IS NOT NULL
    PRINT CONCAT('043: FK on implementation_status_id already exists as ''', @existing_fk_name, '''. Skipping ADD.');
ELSE
BEGIN
    PRINT '043: no FK on implementation_status_id — adding fk_pm_practice_instance_implementation_status.';
    ALTER TABLE grac_practice.practice_instance
        ADD CONSTRAINT fk_pm_practice_instance_implementation_status
            FOREIGN KEY (implementation_status_id)
            REFERENCES grac_practice.implementation_status_master(implementation_status_id);
END
GO

-- =====================================================================
-- 3. Clean up any duplicate FK from a prior v1 run of this migration.
--    v1 created fk_pm_practice_instance_impl_status alongside the
--    canonical fk_pm_practice_instance_implementation_status. Drop the
--    duplicate ONLY IF the canonical one is also present.
-- =====================================================================
IF EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_pm_practice_instance_impl_status'
           AND parent_object_id = OBJECT_ID('grac_practice.practice_instance'))
   AND EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_pm_practice_instance_implementation_status'
               AND parent_object_id = OBJECT_ID('grac_practice.practice_instance'))
BEGIN
    PRINT '043: dropping duplicate FK fk_pm_practice_instance_impl_status left by v1.';
    ALTER TABLE grac_practice.practice_instance
        DROP CONSTRAINT fk_pm_practice_instance_impl_status;
END
GO

-- =====================================================================
-- 4. Supporting index (guarded — safe to keep).
-- =====================================================================
IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE name = 'ix_pm_practice_instance_impl_status'
      AND object_id = OBJECT_ID('grac_practice.practice_instance'))
    CREATE INDEX ix_pm_practice_instance_impl_status
        ON grac_practice.practice_instance(implementation_status_id)
        INCLUDE (organization_id, practice_id, instance_code);
GO

-- =====================================================================
-- 5. Backfill — only rows still NULL (defensive; column is NOT NULL in
--    normal state, so this is usually a no-op).
-- =====================================================================
DECLARE @not_impl_id    INT = (SELECT implementation_status_id FROM grac_practice.implementation_status_master WHERE status_code = N'Not Implemented');
DECLARE @partial_id     INT = (SELECT implementation_status_id FROM grac_practice.implementation_status_master WHERE status_code = N'Partially Implemented');
DECLARE @implemented_id INT = (SELECT implementation_status_id FROM grac_practice.implementation_status_master WHERE status_code = N'Implemented');
DECLARE @na_id          INT = (SELECT implementation_status_id FROM grac_practice.implementation_status_master WHERE status_code = N'N/A');

UPDATE pi
   SET implementation_status_id =
       CASE
         WHEN pi.implementation_status IN (N'Implemented')                            THEN @implemented_id
         WHEN pi.implementation_status IN (N'In Progress', N'Partially Implemented')  THEN @partial_id
         WHEN pi.implementation_status IN (N'N/A', N'NA', N'Not Applicable')          THEN @na_id
         ELSE                                                                              @not_impl_id
       END,
       updated_by = 'backfill-043',
       updated_dt = SYSUTCDATETIME()
FROM grac_practice.practice_instance pi
WHERE pi.implementation_status_id IS NULL;
GO

-- =====================================================================
-- Sanity report
-- =====================================================================
SELECT 'New status master rows present' AS Check_,
       CASE WHEN
           EXISTS (SELECT 1 FROM grac_practice.implementation_status_master WHERE status_code = N'Not Implemented')
       AND EXISTS (SELECT 1 FROM grac_practice.implementation_status_master WHERE status_code = N'Partially Implemented')
       AND EXISTS (SELECT 1 FROM grac_practice.implementation_status_master WHERE status_code = N'N/A')
       THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT 'FK on implementation_status_id (any name)' AS Check_,
       (SELECT COUNT(*) FROM sys.foreign_keys fk
        JOIN sys.foreign_key_columns fkc ON fkc.constraint_object_id = fk.object_id
        JOIN sys.columns c ON c.object_id = fkc.parent_object_id AND c.column_id = fkc.parent_column_id
        WHERE fk.parent_object_id = OBJECT_ID('grac_practice.practice_instance')
          AND c.name = 'implementation_status_id') AS FKCount;

SELECT 'Rows still NULL on implementation_status_id' AS Check_,
       COUNT(*) AS NullRows
FROM grac_practice.practice_instance
WHERE implementation_status_id IS NULL;

SELECT 'Distribution' AS Report,
       ims.status_code, COUNT(*) AS RowCount_
FROM grac_practice.practice_instance pi
LEFT JOIN grac_practice.implementation_status_master ims ON ims.implementation_status_id = pi.implementation_status_id
GROUP BY ims.status_code
ORDER BY ims.status_code;

PRINT '043 practice-instance implementation-status extension complete (v2).';
GO

SET NOEXEC OFF;
GO
