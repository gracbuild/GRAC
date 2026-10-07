-- =====================================================================
-- 433 rollback -- Asset workflows
--
--   * drops the workflow procedures;
--   * drops asset_workflow_case_step, asset_workflow_case,
--     asset_workflow_step and asset_workflow_definition -- every case and
--     its step history is lost. Lifecycle moves the workflows made stay
--     (asset_lifecycle_change and the immutable transition log), as do
--     owner / location changes, assignment history rows and Transfer
--     attestations they raised. practice_audit_trace rows stay.
-- Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOEXEC OFF;
GO

DROP PROCEDURE IF EXISTS grac_practice.sp_asset_workflow_case_get;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_workflow_cases;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_workflow_definitions;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_workflow_cancel;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_workflow_step_action;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_workflow_start;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_workflow_lifecycle;
PRINT '433 rollback: workflow procedures dropped.';
GO

DROP TABLE IF EXISTS grac_practice.asset_workflow_case_step;
DROP TABLE IF EXISTS grac_practice.asset_workflow_case;
DROP TABLE IF EXISTS grac_practice.asset_workflow_step;
DROP TABLE IF EXISTS grac_practice.asset_workflow_definition;
PRINT '433 rollback: workflow tables dropped.';
GO

SELECT '433 rollback: workflow objects gone' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.asset_workflow_case','U') IS NULL
             AND OBJECT_ID('grac_practice.sp_asset_workflow_start','P') IS NULL THEN 'PASS' ELSE 'FAIL' END AS Result;
GO
