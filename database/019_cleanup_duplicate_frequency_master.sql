/*
  GRAC Practice Management
  Cleanup duplicate frequency master records safely.

  Purpose:
  - Keep one active row per business frequency code/name.
  - Mark duplicate active rows as inactive.
  - No physical delete.

  Run this in GRAC_NewPhase.
*/

SET XACT_ABORT ON;
BEGIN TRANSACTION;

PRINT 'Duplicate active frequency values before cleanup';

SELECT
    COALESCE(NULLIF(frequency_code, N''), frequency_name) AS FrequencyKey,
    frequency_name,
    COUNT(*) AS ActiveRows
FROM grac_practice.frequency_master
WHERE is_active = 1
GROUP BY
    COALESCE(NULLIF(frequency_code, N''), frequency_name),
    frequency_name
HAVING COUNT(*) > 1;

;WITH ranked AS (
    SELECT
        frequency_id,
        ROW_NUMBER() OVER (
            PARTITION BY LOWER(LTRIM(RTRIM(COALESCE(NULLIF(frequency_code, N''), frequency_name))))
            ORDER BY display_order, frequency_id
        ) AS row_no
    FROM grac_practice.frequency_master
    WHERE is_active = 1
)
UPDATE f
SET
    is_active = 0,
    updated_by = N'system-cleanup',
    updated_dt = SYSUTCDATETIME()
FROM grac_practice.frequency_master f
JOIN ranked r
    ON r.frequency_id = f.frequency_id
WHERE r.row_no > 1;

PRINT 'Duplicate active frequency values after cleanup';

SELECT
    COALESCE(NULLIF(frequency_code, N''), frequency_name) AS FrequencyKey,
    frequency_name,
    COUNT(*) AS ActiveRows
FROM grac_practice.frequency_master
WHERE is_active = 1
GROUP BY
    COALESCE(NULLIF(frequency_code, N''), frequency_name),
    frequency_name
HAVING COUNT(*) > 1;

COMMIT TRANSACTION;
