-- =====================================================================
-- 386 ROLLBACK  Business Function dependency / Impact category
--
--   * Removes Business Function rows from risk Impact mappings
--     (risk_dependency_map_source / risk_dependency_obligation first).
--   * Retires Business Function resolutions on practice instances
--     (practice_dependency_resolution.is_active = 0 -- that table's soft
--     delete) and inactivates declared practice_instance_dependency rows.
--   * Type -> is_active = 0, is_dependency_mappable = 0; source config ->
--     'Inactive'. Rows are kept, not deleted.
-- Also revert the 386 edits in 272, PracticeRepositoryService.cs and
-- resolve-workspace.cshtml. ASCII-only. Re-runnable.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

DECLARE @bf_type INT = (SELECT TOP 1 dependency_type_id FROM grac_practice.dependency_type_master
                         WHERE dependency_type_code = N'BusinessFunction');
IF @bf_type IS NOT NULL
BEGIN
    IF OBJECT_ID('grac_practice.risk_dependency_map_source','U') IS NOT NULL
        DELETE s FROM grac_practice.risk_dependency_map_source s
          JOIN grac_practice.risk_dependency_map m ON m.risk_dependency_map_id = s.risk_dependency_map_id
         WHERE m.dependency_type_id = @bf_type;
    IF OBJECT_ID('grac_practice.risk_dependency_obligation','U') IS NOT NULL
        DELETE o FROM grac_practice.risk_dependency_obligation o
          JOIN grac_practice.risk_dependency_map m ON m.risk_dependency_map_id = o.risk_dependency_map_id
         WHERE m.dependency_type_id = @bf_type;
    DELETE FROM grac_practice.risk_dependency_map WHERE dependency_type_id = @bf_type;
    PRINT 'ROLLBACK 386: risk mappings removed = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));

    UPDATE grac_practice.practice_dependency_resolution
       SET is_active = 0
     WHERE dependency_type_id = @bf_type AND is_active = 1;
    PRINT 'ROLLBACK 386: practice resolutions retired = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));

    UPDATE grac_practice.practice_instance_dependency
       SET status = N'Inactive'
     WHERE dependency_type_id = @bf_type AND status = N'Active';

    UPDATE grac_practice.dependency_type_source_config
       SET status = N'Inactive', updated_by = N'rollback-386', updated_dt = SYSUTCDATETIME()
     WHERE dependency_type_id = @bf_type;
    UPDATE grac_practice.dependency_type_master
       SET is_active = 0, is_dependency_mappable = 0, updated_by = N'rollback-386', updated_dt = SYSUTCDATETIME()
     WHERE dependency_type_id = @bf_type;
END
PRINT 'ROLLBACK 386 complete.';
GO
