-- =====================================================================
-- 035 State-machine framework — ROLLBACK  (charter §9)
--
-- Reverses everything created by:
--   * database/035_state_machine_framework.sql
--   * database/035_state_machine_procs.sql
--
-- Safety:
--   * Drops in reverse dependency order.
--   * If any {entity}.current_status_id FKs already exist against
--     entity_status_master, the DROP TABLE will fail — that is intentional.
--     Later migrations that introduce such FKs must ship their own
--     rollbacks that run BEFORE this one.
--   * Every DROP guarded with IF EXISTS.
-- =====================================================================
SET NOCOUNT ON;
GO

IF SCHEMA_ID('grac_practice') IS NULL
    THROW 53550, 'PracticeManagement schema grac_practice is missing.', 1;
GO

-- Procedures
IF OBJECT_ID('grac_practice.sp_pm_state_transition','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_pm_state_transition;
GO
IF OBJECT_ID('grac_practice.sp_pm_state_transition_probe','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_pm_state_transition_probe;
GO

-- Functions
IF OBJECT_ID('grac_practice.fn_is_transition_allowed','FN') IS NOT NULL
    DROP FUNCTION grac_practice.fn_is_transition_allowed;
GO
IF OBJECT_ID('grac_practice.fn_get_entity_status_id','FN') IS NOT NULL
    DROP FUNCTION grac_practice.fn_get_entity_status_id;
GO

-- Triggers before tables
IF OBJECT_ID('grac_practice.tr_pm_entity_transition_log_immutable','TR') IS NOT NULL
    DROP TRIGGER grac_practice.tr_pm_entity_transition_log_immutable;
GO

-- Tables (reverse-dependency order)
IF OBJECT_ID('grac_practice.entity_state_transition_log','U') IS NOT NULL
    DROP TABLE grac_practice.entity_state_transition_log;
GO
IF OBJECT_ID('grac_practice.entity_state_transition_rule','U') IS NOT NULL
    DROP TABLE grac_practice.entity_state_transition_rule;
GO
IF OBJECT_ID('grac_practice.entity_status_master','U') IS NOT NULL
    DROP TABLE grac_practice.entity_status_master;
GO

PRINT '035 state-machine framework rollback complete.';
