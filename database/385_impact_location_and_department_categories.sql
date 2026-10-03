-- =====================================================================
-- 385  Impact Details: Location and Department as Impact categories
--
-- REQUEST (sir, 2026-09-26)
-- -------------------------
--   * Location becomes its own category in Risk -> Impact Details
--     (multi-select), no longer a filter on the Person picker.
--   * Department becomes a category too (multi-select). Its picker sits
--     in the Person row: departments narrow the Person list; if no person
--     is ticked, Save stores the DEPARTMENT ids ("everyone in these
--     departments"); if persons are ticked, Save stores the persons.
--   * Confirmed with sir: Department may appear in every dependency-type
--     dropdown (practice instance "Dependencies", Dependencies screen);
--     Location may inherit from practices like the other categories.
--
-- WHAT THIS DOES (data only -- no procedure is re-issued)
-- -------------------------------------------------------
--   1. dependency_type_master: adds 'Department' (code/name 'Department',
--      display_order 10, active, is_dependency_mappable = 1).
--   2. dependency_type_source_config: Department resolves to
--      grac_practice.organization_department (department_id /
--      department_name / organization_id / status = 'Active'), the same
--      shape as every other source row, so the generic dependency-options
--      query can list an organisation's departments. The API's allow-list
--      of source tables gains organization_department in the same change
--      (PracticeRepositoryService.QueryDependencyOptionsFallbackAsync).
--   3. Location: is_dependency_mappable = 1. Its source config
--      (organization_location) already exists since deployment/03 / 272.
--
--   sp_risk_mapping_get lists every active + mappable category, and
--   sp_risk_dependency_map_direct / _unmap accept any active category,
--   so both new categories are saved and read with no procedure change.
--   fn_risk_practice_dependencies (267) inherits every mappable category,
--   so Location resolutions on a mapped practice now flow into the risk
--   as locked, inherited rows -- as agreed.
--
-- ALSO EDITED: 267 and 353 no longer switch Location OFF (a re-run would
--   have reverted this), and 272 seeds the Department type + source row.
--
-- Re-runnable: yes. Rollback: 385_impact_location_and_department_categories_rollback.sql
-- DEPENDS ON: 267 (is_dependency_mappable), deployment/03 or 272 (types,
--   source config), 002 (organization_department).
-- ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET NOEXEC OFF;
GO

DECLARE @ok BIT = 1;
IF COL_LENGTH('grac_practice.dependency_type_master','is_dependency_mappable') IS NULL
BEGIN PRINT 'ABORT (385): dependency_type_master.is_dependency_mappable missing. Run 267 first.'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.dependency_type_source_config','U') IS NULL
BEGIN PRINT 'ABORT (385): dependency_type_source_config missing.'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.organization_department','U') IS NULL
BEGIN PRINT 'ABORT (385): organization_department missing.'; SET @ok = 0; END
IF @ok = 0
BEGIN
    RAISERROR('385_impact_location_and_department_categories: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

-- ---------------------------------------------------------------------
-- 1. Department dependency type.
-- ---------------------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM grac_practice.dependency_type_master
                WHERE dependency_type_code = N'Department' OR dependency_type_name = N'Department')
    INSERT grac_practice.dependency_type_master
        (dependency_type_code, dependency_type_name, display_order, is_active, is_dependency_mappable, entered_by)
    VALUES (N'Department', N'Department', 10, 1, 1, N'seed-385');
ELSE
    UPDATE grac_practice.dependency_type_master
       SET is_active = 1, is_dependency_mappable = 1,
           updated_by = N'seed-385', updated_dt = SYSUTCDATETIME()
     WHERE (dependency_type_code = N'Department' OR dependency_type_name = N'Department')
       AND (is_active = 0 OR is_dependency_mappable = 0);
PRINT '385: Department dependency type ensured.';
GO

-- ---------------------------------------------------------------------
-- 2. Department source config.
-- ---------------------------------------------------------------------
DECLARE @dept_type INT = (SELECT TOP 1 dependency_type_id FROM grac_practice.dependency_type_master
                           WHERE dependency_type_code = N'Department' OR dependency_type_name = N'Department'
                           ORDER BY dependency_type_id);
DECLARE @active_rs INT = (SELECT TOP 1 record_status_id FROM grac_practice.record_status_master
                           WHERE status_code = N'Active' OR status_name = N'Active' ORDER BY record_status_id);

IF NOT EXISTS (SELECT 1 FROM grac_practice.dependency_type_source_config WHERE dependency_type_id = @dept_type)
    INSERT grac_practice.dependency_type_source_config
        (dependency_type_id, dependency_type_name, source_type, source_table_name,
         id_column_name, display_column_name, organization_filter_column,
         status_filter_column, status_active_value, sort_column,
         is_multi_select_allowed, status, record_status_id, entered_by)
    VALUES (@dept_type, N'Department', N'Department', N'grac_practice.organization_department',
            N'department_id', N'department_name', N'organization_id',
            N'status', N'Active', N'department_name',
            1, N'Active', @active_rs, N'seed-385');
ELSE
    UPDATE grac_practice.dependency_type_source_config
       SET source_table_name = N'grac_practice.organization_department',
           id_column_name = N'department_id', display_column_name = N'department_name',
           organization_filter_column = N'organization_id', status_filter_column = N'status',
           status_active_value = N'Active', sort_column = N'department_name',
           status = N'Active', updated_by = N'seed-385', updated_dt = SYSUTCDATETIME()
     WHERE dependency_type_id = @dept_type
       AND (source_table_name <> N'grac_practice.organization_department' OR status <> N'Active');
PRINT '385: Department source config ensured.';
GO

-- ---------------------------------------------------------------------
-- 3. Location is an Impact category.
-- ---------------------------------------------------------------------
UPDATE grac_practice.dependency_type_master
   SET is_dependency_mappable = 1, updated_by = N'seed-385', updated_dt = SYSUTCDATETIME()
 WHERE (dependency_type_code IN (N'Location', N'LOCATION') OR dependency_type_name = N'Location')
   AND is_dependency_mappable = 0;
PRINT '385: Location made mappable rows = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

-- ---------------------------------------------------------------------
-- Verification
-- ---------------------------------------------------------------------
SELECT '385-a Department type active and mappable' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM grac_practice.dependency_type_master
                          WHERE dependency_type_code = N'Department' AND is_active = 1 AND is_dependency_mappable = 1)
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '385-b Department resolves to organization_department',
       CASE WHEN EXISTS (SELECT 1 FROM grac_practice.dependency_type_source_config sc
                           JOIN grac_practice.dependency_type_master dt ON dt.dependency_type_id = sc.dependency_type_id
                          WHERE dt.dependency_type_code = N'Department' AND sc.status = N'Active'
                            AND sc.source_table_name = N'grac_practice.organization_department')
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '385-c Location mappable and has an active source',
       CASE WHEN EXISTS (SELECT 1 FROM grac_practice.dependency_type_master dt
                           JOIN grac_practice.dependency_type_source_config sc
                             ON sc.dependency_type_id = dt.dependency_type_id AND sc.status = N'Active'
                          WHERE dt.dependency_type_name = N'Location' AND dt.is_active = 1 AND dt.is_dependency_mappable = 1)
            THEN 'PASS' ELSE 'FAIL' END;

PRINT '--- Impact Details categories now offered ---';
SELECT dependency_type_id, dependency_type_code, dependency_type_name, display_order
  FROM grac_practice.dependency_type_master
 WHERE is_active = 1 AND is_dependency_mappable = 1
 ORDER BY display_order, dependency_type_name;

PRINT '385 complete.';
GO
SET NOEXEC OFF;
GO
