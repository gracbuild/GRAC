-- =====================================================================
-- 386  Business Function as a dependency / Impact category
--
-- REQUEST (sir, 2026-09-27)
-- -------------------------
--   Business Function becomes a category in Risk -> Impact Details AND
--   in the Operationalize Dependencies table.
--
-- WHAT THIS DOES (data only -- no procedure is re-issued)
-- -------------------------------------------------------
--   1. dependency_type_master: adds 'Business Function' (code
--      'BusinessFunction', display_order 11, active,
--      is_dependency_mappable = 1 so Impact Details offers it).
--   2. dependency_type_source_config: resolves to
--      grac_practice.organization_business_function (business_function_id
--      / function_name / organization_id / status = 'Active').
--
--   Nothing else has to change in SQL:
--     * sp_risk_mapping_get lists every active + mappable category;
--       sp_risk_dependency_map_direct / _unmap accept any active one.
--     * Operationalize: sp_resolve_dependency_type_list returns every
--       active type, and sp_resolve_dependency_category_sync (238) saves
--       any active type -- the client sends each object's name, so its
--       source-table allow-list (used only to back-fill missing names)
--       does not need the new table.
--     * fn_risk_practice_dependencies (267) inherits every mappable
--       category, so Business Functions resolved on a practice flow into
--       its risks as locked, inherited rows -- same as the others.
--   Code in the same change: the API's dependency-options allow-list
--   gains organization_business_function, and the Operationalize table's
--   fixed category list (resolve-workspace.cshtml DEP_TABLE_CATEGORIES)
--   gains 'Business Function'.
--   Like Department (385) it also appears in every dependency-type
--   dropdown (lookups list every active type).
--
-- ALSO EDITED: 272 seeds the type + source row.
-- Re-runnable: yes. Rollback: 386_business_function_dependency_category_rollback.sql
-- DEPENDS ON: 267 (is_dependency_mappable), deployment/03 or 272.
-- ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET NOEXEC OFF;
GO

DECLARE @ok BIT = 1;
IF COL_LENGTH('grac_practice.dependency_type_master','is_dependency_mappable') IS NULL
BEGIN PRINT 'ABORT (386): dependency_type_master.is_dependency_mappable missing. Run 267 first.'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.dependency_type_source_config','U') IS NULL
BEGIN PRINT 'ABORT (386): dependency_type_source_config missing.'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.organization_business_function','U') IS NULL
BEGIN PRINT 'ABORT (386): organization_business_function missing.'; SET @ok = 0; END
IF @ok = 0
BEGIN
    RAISERROR('386_business_function_dependency_category: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

-- 1. Type.
IF NOT EXISTS (SELECT 1 FROM grac_practice.dependency_type_master
                WHERE dependency_type_code = N'BusinessFunction' OR dependency_type_name = N'Business Function')
    INSERT grac_practice.dependency_type_master
        (dependency_type_code, dependency_type_name, display_order, is_active, is_dependency_mappable, entered_by)
    VALUES (N'BusinessFunction', N'Business Function', 11, 1, 1, N'seed-386');
ELSE
    UPDATE grac_practice.dependency_type_master
       SET is_active = 1, is_dependency_mappable = 1,
           updated_by = N'seed-386', updated_dt = SYSUTCDATETIME()
     WHERE (dependency_type_code = N'BusinessFunction' OR dependency_type_name = N'Business Function')
       AND (is_active = 0 OR is_dependency_mappable = 0);
PRINT '386: Business Function dependency type ensured.';
GO

-- 2. Source config.
DECLARE @bf_type INT = (SELECT TOP 1 dependency_type_id FROM grac_practice.dependency_type_master
                         WHERE dependency_type_code = N'BusinessFunction' OR dependency_type_name = N'Business Function'
                         ORDER BY dependency_type_id);
DECLARE @active_rs INT = (SELECT TOP 1 record_status_id FROM grac_practice.record_status_master
                           WHERE status_code = N'Active' OR status_name = N'Active' ORDER BY record_status_id);

IF NOT EXISTS (SELECT 1 FROM grac_practice.dependency_type_source_config WHERE dependency_type_id = @bf_type)
    INSERT grac_practice.dependency_type_source_config
        (dependency_type_id, dependency_type_name, source_type, source_table_name,
         id_column_name, display_column_name, organization_filter_column,
         status_filter_column, status_active_value, sort_column,
         is_multi_select_allowed, status, record_status_id, entered_by)
    VALUES (@bf_type, N'Business Function', N'Business Function', N'grac_practice.organization_business_function',
            N'business_function_id', N'function_name', N'organization_id',
            N'status', N'Active', N'function_name',
            1, N'Active', @active_rs, N'seed-386');
ELSE
    UPDATE grac_practice.dependency_type_source_config
       SET source_table_name = N'grac_practice.organization_business_function',
           id_column_name = N'business_function_id', display_column_name = N'function_name',
           organization_filter_column = N'organization_id', status_filter_column = N'status',
           status_active_value = N'Active', sort_column = N'function_name',
           status = N'Active', updated_by = N'seed-386', updated_dt = SYSUTCDATETIME()
     WHERE dependency_type_id = @bf_type
       AND (source_table_name <> N'grac_practice.organization_business_function' OR status <> N'Active');
PRINT '386: Business Function source config ensured.';
GO

-- Verification
SELECT '386-a Business Function type active and mappable' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM grac_practice.dependency_type_master
                          WHERE dependency_type_code = N'BusinessFunction' AND is_active = 1 AND is_dependency_mappable = 1)
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '386-b Business Function resolves to organization_business_function',
       CASE WHEN EXISTS (SELECT 1 FROM grac_practice.dependency_type_source_config sc
                           JOIN grac_practice.dependency_type_master dt ON dt.dependency_type_id = sc.dependency_type_id
                          WHERE dt.dependency_type_code = N'BusinessFunction' AND sc.status = N'Active'
                            AND sc.source_table_name = N'grac_practice.organization_business_function')
            THEN 'PASS' ELSE 'FAIL' END;

PRINT '386 complete.';
GO
SET NOEXEC OFF;
GO
