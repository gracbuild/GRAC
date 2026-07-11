/*  ============================================================
    025_seed_resolution_status_master.sql
    Seeds dependency_resolution_status_master with required entries.

    Root cause of Task #23: The stored procedure's resolved_categories
    CTE used INNER JOIN on this table. If empty, no resolutions were
    ever counted, so status always showed 'Pending'.

    The stored procedure has been fixed to use the resolution_status
    column directly (no FK dependency), but this seed ensures the
    master table is populated for any code that references it.
    ============================================================ */

-- Seed using MERGE (matches deployment script pattern)
;WITH seed(status_code, status_name, display_order) AS (
    SELECT N'Pending',  N'Pending',  1 UNION ALL
    SELECT N'Resolved', N'Resolved', 2
)
MERGE grac_practice.dependency_resolution_status_master AS target
USING seed AS source
ON target.status_code = source.status_code
WHEN MATCHED THEN
    UPDATE SET status_name = source.status_name,
               display_order = source.display_order,
               is_active = 1,
               updated_by = N'system',
               updated_dt = SYSUTCDATETIME()
WHEN NOT MATCHED THEN
    INSERT (status_code, status_name, display_order, is_active, entered_by)
    VALUES (source.status_code, source.status_name, source.display_order, 1, N'system');

PRINT 'Seeded dependency_resolution_status_master.';

-- Also backfill resolution_status_id on any existing resolution rows where it is NULL
DECLARE @resolved_status_id INT;
SELECT @resolved_status_id = resolution_status_id
FROM grac_practice.dependency_resolution_status_master
WHERE status_code = 'Resolved';

IF @resolved_status_id IS NOT NULL
BEGIN
    UPDATE grac_practice.practice_dependency_resolution
    SET resolution_status_id = @resolved_status_id
    WHERE resolution_status_id IS NULL
      AND resolution_status = N'Resolved'
      AND is_active = 1;

    PRINT 'Backfilled resolution_status_id on ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' resolution rows.';
END

-- Verify
SELECT * FROM grac_practice.dependency_resolution_status_master ORDER BY display_order;
