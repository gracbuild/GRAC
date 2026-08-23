-- =====================================================================
-- 109 rollback -- Drop the columns / constraints / indexes added by
-- migration 109. Preserves data by NOT dropping the base table.
-- =====================================================================
SET NOCOUNT ON;
GO

-- Drop new indexes.
IF EXISTS (SELECT 1 FROM sys.indexes
           WHERE name='ix_pm_custom_gap_source_ref'
             AND object_id = OBJECT_ID('grac_practice.custom_gap'))
    DROP INDEX ix_pm_custom_gap_source_ref ON grac_practice.custom_gap;
GO
IF EXISTS (SELECT 1 FROM sys.indexes
           WHERE name='ix_pm_custom_gap_source_module'
             AND object_id = OBJECT_ID('grac_practice.custom_gap'))
    DROP INDEX ix_pm_custom_gap_source_module ON grac_practice.custom_gap;
GO

-- Restore original status CHECK (Open/InProgress/Closed/Cancelled).
IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_custom_gap_status')
    ALTER TABLE grac_practice.custom_gap DROP CONSTRAINT ck_pm_custom_gap_status;
GO
ALTER TABLE grac_practice.custom_gap
    ADD CONSTRAINT ck_pm_custom_gap_status CHECK (status IN (
        N'Open', N'InProgress', N'Closed', N'Cancelled'));
GO

-- Drop source-module CHECK.
IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_custom_gap_source_module')
    ALTER TABLE grac_practice.custom_gap DROP CONSTRAINT ck_pm_custom_gap_source_module;
GO

-- Drop default on gap_source_module_code before dropping the column.
DECLARE @df NVARCHAR(200);
SELECT @df = dc.name
FROM sys.default_constraints dc
JOIN sys.columns c ON c.default_object_id = dc.object_id
WHERE c.object_id = OBJECT_ID('grac_practice.custom_gap')
  AND c.name = 'gap_source_module_code';
IF @df IS NOT NULL
    EXEC('ALTER TABLE grac_practice.custom_gap DROP CONSTRAINT ' + @df);
GO

-- Drop all added columns (order does not matter -- none reference each other).
DECLARE @cols TABLE(col_name SYSNAME);
INSERT INTO @cols(col_name) VALUES
    ('gap_source_module_code'),('source_reference_type'),('source_reference_id'),
    ('severity_code'),('severity_name'),
    ('execution_code'),('execution_name'),
    ('entity_dimension_code'),('entity_dimension_name'),
    ('entity_code'),('entity_name'),
    ('observation_code'),('observation_title'),
    ('owner_display_name'),
    ('assigned_reviewer_employee_id'),('assigned_reviewer_display_name'),
    ('remediation_plan'),('resolution_notes'),
    ('verification_notes'),('closure_notes'),
    ('target_resolution_date'),
    ('opened_dt'),('remediation_submitted_dt'),
    ('verified_dt'),('closed_dt'),('reopened_dt'),
    ('risk_id');

DECLARE @sql NVARCHAR(400);
DECLARE cur CURSOR LOCAL FAST_FORWARD FOR SELECT col_name FROM @cols;
OPEN cur;
DECLARE @c SYSNAME;
FETCH NEXT FROM cur INTO @c;
WHILE @@FETCH_STATUS = 0
BEGIN
    IF COL_LENGTH('grac_practice.custom_gap', @c) IS NOT NULL
    BEGIN
        SET @sql = 'ALTER TABLE grac_practice.custom_gap DROP COLUMN ' + QUOTENAME(@c);
        EXEC sp_executesql @sql;
    END
    FETCH NEXT FROM cur INTO @c;
END
CLOSE cur; DEALLOCATE cur;
GO

PRINT '109 rollback complete -- custom_gap columns/constraints/indexes removed.';
GO
