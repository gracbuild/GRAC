-- =====================================================================
-- 115 rollback -- drop the role columns added to Assurance module tables.
-- Preserves data by NOT touching employee_id columns.
-- =====================================================================
SET NOCOUNT ON;
GO

DECLARE @drop TABLE(table_name SYSNAME, col_name SYSNAME);
INSERT @drop(table_name, col_name) VALUES
    ('org_assurance_definition',        'owner_role_id'),
    ('org_assurance_definition',        'owner_role_name'),
    ('org_assurance_observation',       'assigned_owner_role_id'),
    ('org_assurance_observation',       'assigned_owner_role_name'),
    ('org_assurance_observation',       'assigned_reviewer_role_id'),
    ('org_assurance_observation',       'assigned_reviewer_role_name'),
    ('custom_gap',                      'owner_role_id'),
    ('custom_gap',                      'owner_role_name'),
    ('custom_gap',                      'assigned_reviewer_role_id'),
    ('custom_gap',                      'assigned_reviewer_role_name'),
    ('custom_gap_action',               'assigned_role_id'),
    ('custom_gap_action',               'assigned_role_name'),
    ('org_assurance_execution',         'owner_role_id'),
    ('org_assurance_execution',         'owner_role_name'),
    ('org_assurance_execution_entity',  'assigned_auditor_role_id'),
    ('org_assurance_execution_entity',  'assigned_auditor_role_name'),
    ('org_assurance_plan',              'owner_role_id'),
    ('org_assurance_plan',              'owner_role_name'),
    ('org_assurance_plan_item',         'assigned_auditor_role_id'),
    ('org_assurance_plan_item',         'assigned_auditor_role_name');

DECLARE cur CURSOR LOCAL FAST_FORWARD FOR SELECT table_name, col_name FROM @drop;
OPEN cur;
DECLARE @t SYSNAME, @c SYSNAME, @sql NVARCHAR(400);
FETCH NEXT FROM cur INTO @t, @c;
WHILE @@FETCH_STATUS = 0
BEGIN
    IF OBJECT_ID('grac_practice.' + @t, 'U') IS NOT NULL
       AND COL_LENGTH('grac_practice.' + @t, @c) IS NOT NULL
    BEGIN
        SET @sql = 'ALTER TABLE grac_practice.' + QUOTENAME(@t) + ' DROP COLUMN ' + QUOTENAME(@c);
        EXEC sp_executesql @sql;
    END
    FETCH NEXT FROM cur INTO @t, @c;
END
CLOSE cur; DEALLOCATE cur;
GO

PRINT '115 rollback complete.';
GO
