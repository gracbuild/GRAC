-- =====================================================================
-- 427 rollback -- operating-system products, releases and compatibility
--
--   * drops the eight procedures and the three tables (children first) --
--     every OS product, release and compatibility record is lost;
--   * removes the OS rows from technology_lifecycle_event (425's table
--     stays);
--   * removes the OsRelease transition rules, and its statuses where no
--     (immutable) transition-log row references them.
-- practice_audit_trace rows are immutable and stay as history.
-- Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.sp_asset_os_list','P') IS NOT NULL               DROP PROCEDURE grac_practice.sp_asset_os_list;
IF OBJECT_ID('grac_practice.sp_asset_os_release_get','P') IS NOT NULL        DROP PROCEDURE grac_practice.sp_asset_os_release_get;
IF OBJECT_ID('grac_practice.sp_asset_model_os_list','P') IS NOT NULL         DROP PROCEDURE grac_practice.sp_asset_model_os_list;
IF OBJECT_ID('grac_practice.sp_asset_os_product_save','P') IS NOT NULL       DROP PROCEDURE grac_practice.sp_asset_os_product_save;
IF OBJECT_ID('grac_practice.sp_asset_os_release_save','P') IS NOT NULL       DROP PROCEDURE grac_practice.sp_asset_os_release_save;
IF OBJECT_ID('grac_practice.sp_asset_os_release_transition','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_asset_os_release_transition;
IF OBJECT_ID('grac_practice.sp_asset_os_compat_save','P') IS NOT NULL        DROP PROCEDURE grac_practice.sp_asset_os_compat_save;
IF OBJECT_ID('grac_practice.sp_asset_os_compat_approve','P') IS NOT NULL     DROP PROCEDURE grac_practice.sp_asset_os_compat_approve;
PRINT '427 rollback: procedures dropped.';
GO

IF OBJECT_ID('grac_practice.asset_os_compatibility','U') IS NOT NULL DROP TABLE grac_practice.asset_os_compatibility;
IF OBJECT_ID('grac_practice.asset_os_release','U') IS NOT NULL       DROP TABLE grac_practice.asset_os_release;
IF OBJECT_ID('grac_practice.asset_os_product','U') IS NOT NULL       DROP TABLE grac_practice.asset_os_product;
IF OBJECT_ID('grac_practice.technology_lifecycle_event','U') IS NOT NULL
    DELETE FROM grac_practice.technology_lifecycle_event WHERE entity_type = N'OS';
PRINT '427 rollback: tables dropped.';
GO

DELETE FROM grac_practice.entity_state_transition_rule WHERE entity_type = N'OsRelease';
DELETE s FROM grac_practice.entity_status_master s
 WHERE s.entity_type = N'OsRelease'
   AND NOT EXISTS (SELECT 1 FROM grac_practice.entity_state_transition_log l
                    WHERE l.from_status_id = s.entity_status_id OR l.to_status_id = s.entity_status_id);
PRINT '427 rollback: lifecycle rows removed.';
GO
