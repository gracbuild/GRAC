-- =====================================================================
-- 044 Simplify implementation-status value set + reset default
--
-- User requirement:
--   The valid Implementation Status values for Practice Instance shall be:
--     * Implemented
--     * Not Implemented
--     * Not Updated
--   Existing rows (which were previously seeded as 'Active' or backfilled
--   to 'Not Implemented' via migration 043) shall all be set to
--   'Not Implemented' as the current default.
--
-- Design decisions:
--   * Existing rows Partially Implemented / N/A in the master table are
--     KEPT but marked is_active = 0. They cannot be selected in the UI
--     but any existing FK reference remains valid — safest against
--     downstream code that hard-codes the values.
--   * Column DEFAULT on practice_instance.implementation_status is
--     changed from 'Active' to 'Not Implemented'.
--   * ALL practice_instance rows are updated to point to the
--     'Not Implemented' surrogate + text label. Idempotent — safe to
--     re-run.
--
-- Rollback: database/044_practice_instance_impl_status_reset_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

-- Prerequisite guard.
DECLARE @prereqs_ok BIT = 1;

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    PRINT 'ABORT (044): schema grac_practice missing.';
    SET @prereqs_ok = 0;
END

IF OBJECT_ID('grac_practice.implementation_status_master','U') IS NULL
BEGIN
    PRINT 'ABORT (044): implementation_status_master missing.';
    SET @prereqs_ok = 0;
END

IF OBJECT_ID('grac_practice.practice_instance','U') IS NULL
BEGIN
    PRINT 'ABORT (044): practice_instance missing.';
    SET @prereqs_ok = 0;
END

IF COL_LENGTH('grac_practice.practice_instance','implementation_status_id') IS NULL
BEGIN
    PRINT 'ABORT (044): implementation_status_id column missing. Run 043 first.';
    SET @prereqs_ok = 0;
END

IF @prereqs_ok = 0
BEGIN
    RAISERROR('044 prerequisites missing — see PRINT above.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. Seed 'Not Updated' (idempotent MERGE)
--    display_order set below Implemented so the dropdown shows:
--      Implemented (30) — Not Implemented (10) — Not Updated (15)
-- =====================================================================
;WITH src AS (
    SELECT * FROM (VALUES
        (N'Not Updated', N'Not Updated', 15)
    ) v(status_code, status_name, display_order)
)
MERGE grac_practice.implementation_status_master AS t
USING src
   ON t.status_code = src.status_code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (status_code, status_name, display_order, is_active, entered_by)
    VALUES (src.status_code, src.status_name, src.display_order, 1, 'seed-044')
WHEN MATCHED AND (t.status_name <> src.status_name OR t.display_order <> src.display_order OR t.is_active = 0) THEN
    UPDATE SET status_name  = src.status_name,
               display_order= src.display_order,
               is_active    = 1,
               updated_by   = 'seed-044',
               updated_dt   = SYSUTCDATETIME();
GO

-- =====================================================================
-- 2. Deactivate values not in the accepted set
--    Accepted (active) set = { Implemented, Not Implemented, Not Updated }
--    Everything else (including 043 seeds Partially Implemented and N/A,
--    plus legacy Not Started / In Progress / Active / Inactive) is
--    marked is_active = 0. Rows are preserved for FK integrity.
-- =====================================================================
UPDATE grac_practice.implementation_status_master
   SET is_active  = 0,
       updated_by = 'seed-044',
       updated_dt = SYSUTCDATETIME()
 WHERE status_code NOT IN (N'Implemented', N'Not Implemented', N'Not Updated')
   AND is_active = 1;
GO

-- Ensure the three accepted values are all is_active = 1
UPDATE grac_practice.implementation_status_master
   SET is_active  = 1,
       updated_by = 'seed-044',
       updated_dt = SYSUTCDATETIME()
 WHERE status_code IN (N'Implemented', N'Not Implemented', N'Not Updated')
   AND is_active = 0;
GO

-- =====================================================================
-- 3. Change the column DEFAULT constraint on practice_instance.implementation_status
--    from 'Active' to 'Not Implemented' so new inserts get the right label.
--    The default constraint's name is not stable across environments — look it up.
-- =====================================================================
DECLARE @df_name NVARCHAR(200);
SELECT @df_name = dc.name
FROM sys.default_constraints dc
JOIN sys.columns c ON c.object_id = dc.parent_object_id AND c.column_id = dc.parent_column_id
WHERE dc.parent_object_id = OBJECT_ID('grac_practice.practice_instance')
  AND c.name = 'implementation_status';

IF @df_name IS NOT NULL
BEGIN
    DECLARE @drop_sql NVARCHAR(400) = CONCAT(N'ALTER TABLE grac_practice.practice_instance DROP CONSTRAINT ', QUOTENAME(@df_name), N';');
    PRINT CONCAT('044: dropping existing default constraint ', @df_name);
    EXEC sp_executesql @drop_sql;
END

ALTER TABLE grac_practice.practice_instance
    ADD CONSTRAINT df_pm_practice_instance_impl_status
    DEFAULT N'Not Implemented' FOR implementation_status;
GO

-- =====================================================================
-- 4. Force ALL existing practice_instance rows to 'Not Implemented'
--    Idempotent — repeated runs converge to the same state.
-- =====================================================================
DECLARE @not_impl_id INT =
    (SELECT implementation_status_id FROM grac_practice.implementation_status_master WHERE status_code = N'Not Implemented');

IF @not_impl_id IS NULL
    THROW 54400, 'seed row Not Implemented missing after step 1.', 1;

UPDATE grac_practice.practice_instance
   SET implementation_status    = N'Not Implemented',
       implementation_status_id = @not_impl_id,
       updated_by               = 'seed-044',
       updated_dt               = SYSUTCDATETIME()
 WHERE implementation_status_id IS NULL
    OR implementation_status_id <> @not_impl_id
    OR implementation_status IS NULL
    OR implementation_status <> N'Not Implemented';
GO

-- =====================================================================
-- Sanity report
-- =====================================================================
SELECT 'Accepted status master rows (active)' AS Check_,
       COUNT(*) AS ActiveCount
FROM grac_practice.implementation_status_master
WHERE status_code IN (N'Implemented', N'Not Implemented', N'Not Updated')
  AND is_active = 1;

SELECT 'Non-accepted status master rows (should all be inactive)' AS Check_,
       CASE WHEN NOT EXISTS (
           SELECT 1 FROM grac_practice.implementation_status_master
           WHERE status_code NOT IN (N'Implemented', N'Not Implemented', N'Not Updated')
             AND is_active = 1)
           THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT 'Column default constraint value' AS Check_,
       OBJECT_DEFINITION((
           SELECT dc.object_id FROM sys.default_constraints dc
           JOIN sys.columns c ON c.object_id = dc.parent_object_id AND c.column_id = dc.parent_column_id
           WHERE dc.parent_object_id = OBJECT_ID('grac_practice.practice_instance')
             AND c.name = 'implementation_status')) AS Definition;

SELECT 'Practice Instance distribution' AS Report,
       ims.status_code, COUNT(*) AS RowCount_
FROM grac_practice.practice_instance pi
LEFT JOIN grac_practice.implementation_status_master ims ON ims.implementation_status_id = pi.implementation_status_id
GROUP BY ims.status_code
ORDER BY ims.status_code;

PRINT '044 implementation-status simplification + reset complete.';
GO

SET NOEXEC OFF;
GO
