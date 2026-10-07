-- =====================================================================
-- 453 ROLLBACK  Asset report schedules, distribution and retention
-- =====================================================================
-- Drops the 453 procedures, functions and tables (schedules, deliveries
-- and delivered files are lost) and asset_report_export.delivery_
-- recipient_id (downloads stay in the export log without the delivery
-- reference). 453 re-issues no existing object. Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_report_delivery_download;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_report_my_deliveries;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_report_delivery_recipients;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_report_deliveries;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_report_delivery_store;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_report_delivery_start;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_report_delivery_finish;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_report_schedule_save;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_report_schedules;
DROP FUNCTION IF EXISTS grac_practice.fn_asset_report_employee_access;
DROP FUNCTION IF EXISTS grac_practice.fn_asset_report_employee_in_org;
DROP FUNCTION IF EXISTS grac_practice.fn_asset_report_next_run;
GO
IF COL_LENGTH('grac_practice.asset_report_export', 'delivery_recipient_id') IS NOT NULL
BEGIN
    IF OBJECT_ID('grac_practice.fk_pm_arpt_exp_drcp', 'F') IS NOT NULL
        ALTER TABLE grac_practice.asset_report_export DROP CONSTRAINT fk_pm_arpt_exp_drcp;
    ALTER TABLE grac_practice.asset_report_export DROP COLUMN delivery_recipient_id;
END
GO
DROP TABLE IF EXISTS grac_practice.asset_report_delivery_recipient;
DROP TABLE IF EXISTS grac_practice.asset_report_delivery;
DROP TABLE IF EXISTS grac_practice.asset_report_schedule_recipient;
DROP TABLE IF EXISTS grac_practice.asset_report_schedule;
GO
PRINT '453 rollback: schedule and delivery objects dropped.';
GO
SELECT '453 rollback' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.asset_report_schedule','U') IS NULL
             AND OBJECT_ID('grac_practice.sp_asset_report_delivery_start','P') IS NULL
             AND COL_LENGTH('grac_practice.asset_report_export', 'delivery_recipient_id') IS NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;
GO
