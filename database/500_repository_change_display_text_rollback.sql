-- =====================================================================
-- 500_repository_change_display_text_rollback.sql
--
-- Undoes 500_repository_change_display_text.sql:
--   * grac_practice.sp_repository_change_display
--   * grac_practice.fn_repo_field_label
--   * grac_practice.repository_change_field_config
--
-- Nothing else is touched. 500 is display-only: detection, approval,
-- sp_repository_change_list and the stored snapshots are unchanged, so
-- after this the Repository Updates page falls back to its own
-- client-side diff (raw column names and ids) with no loss of data.
--
-- SAFE TO RE-RUN. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.sp_repository_change_display','P') IS NOT NULL
BEGIN
    DROP PROCEDURE grac_practice.sp_repository_change_display;
    PRINT '500 rollback: sp_repository_change_display dropped.';
END
GO

IF OBJECT_ID('grac_practice.fn_repo_field_label','FN') IS NOT NULL
BEGIN
    DROP FUNCTION grac_practice.fn_repo_field_label;
    PRINT '500 rollback: fn_repo_field_label dropped.';
END
GO

IF OBJECT_ID('grac_practice.repository_change_field_config','U') IS NOT NULL
BEGIN
    DROP TABLE grac_practice.repository_change_field_config;
    PRINT '500 rollback: repository_change_field_config dropped.';
END
GO

PRINT '--- 500 rollback verification ---';
SELECT CASE WHEN OBJECT_ID('grac_practice.repository_change_field_config','U') IS NULL
            THEN 'gone' ELSE 'STILL THERE' END AS field_config_table,
       CASE WHEN OBJECT_ID('grac_practice.fn_repo_field_label','FN') IS NULL
            THEN 'gone' ELSE 'STILL THERE' END AS label_function,
       CASE WHEN OBJECT_ID('grac_practice.sp_repository_change_display','P') IS NULL
            THEN 'gone' ELSE 'STILL THERE' END AS display_procedure;
PRINT '500 rollback: done.';
GO
