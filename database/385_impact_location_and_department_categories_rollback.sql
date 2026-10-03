-- =====================================================================
-- 385 ROLLBACK  Location / Department as Impact categories
--
--   * Removes every risk Impact mapping of the Department category
--     (risk_dependency_map_source and risk_dependency_obligation rows
--     first, then risk_dependency_map).
--   * Department type -> is_active = 0, is_dependency_mappable = 0, and
--     its source config -> 'Inactive'. The type row is kept (not deleted)
--     so any other reference to its id cannot break.
--   * Location -> is_dependency_mappable = 0. Existing Location mappings
--     on risks are left in place; re-running 267 section 4 clears them.
--
-- Also revert the 385 edits in 267, 353 and 272. ASCII-only. Re-runnable.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

DECLARE @dept_type INT = (SELECT TOP 1 dependency_type_id FROM grac_practice.dependency_type_master
                           WHERE dependency_type_code = N'Department');
IF @dept_type IS NOT NULL
BEGIN
    IF OBJECT_ID('grac_practice.risk_dependency_map_source','U') IS NOT NULL
        DELETE s FROM grac_practice.risk_dependency_map_source s
          JOIN grac_practice.risk_dependency_map m ON m.risk_dependency_map_id = s.risk_dependency_map_id
         WHERE m.dependency_type_id = @dept_type;
    IF OBJECT_ID('grac_practice.risk_dependency_obligation','U') IS NOT NULL
        DELETE o FROM grac_practice.risk_dependency_obligation o
          JOIN grac_practice.risk_dependency_map m ON m.risk_dependency_map_id = o.risk_dependency_map_id
         WHERE m.dependency_type_id = @dept_type;
    DELETE FROM grac_practice.risk_dependency_map WHERE dependency_type_id = @dept_type;
    PRINT 'ROLLBACK 385: Department risk mappings removed = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));

    UPDATE grac_practice.dependency_type_source_config
       SET status = N'Inactive', updated_by = N'rollback-385', updated_dt = SYSUTCDATETIME()
     WHERE dependency_type_id = @dept_type;
    UPDATE grac_practice.dependency_type_master
       SET is_active = 0, is_dependency_mappable = 0, updated_by = N'rollback-385', updated_dt = SYSUTCDATETIME()
     WHERE dependency_type_id = @dept_type;
END
GO

UPDATE grac_practice.dependency_type_master
   SET is_dependency_mappable = 0, updated_by = N'rollback-385', updated_dt = SYSUTCDATETIME()
 WHERE dependency_type_name = N'Location';
PRINT 'ROLLBACK 385 complete.';
GO
