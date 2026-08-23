-- =====================================================================
-- 178 Organization SLA Config schema -- ROLLBACK
--
-- Drops in dependency order:
--   org_sla_process_binding      (FKs org_sla_config, sla_process_type_master)
--   org_sla_config_notify_role   (FK org_sla_config)
--   org_sla_config               (FK organization, record_status_master)
--   sla_process_type_master      (leaf)
--
-- Safe to re-run.
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.org_sla_process_binding','U') IS NOT NULL
    DROP TABLE grac_practice.org_sla_process_binding;
GO

IF OBJECT_ID('grac_practice.org_sla_config_notify_role','U') IS NOT NULL
    DROP TABLE grac_practice.org_sla_config_notify_role;
GO

IF OBJECT_ID('grac_practice.org_sla_config','U') IS NOT NULL
    DROP TABLE grac_practice.org_sla_config;
GO

IF OBJECT_ID('grac_practice.sla_process_type_master','U') IS NOT NULL
    DROP TABLE grac_practice.sla_process_type_master;
GO

PRINT '178 Organization SLA Config schema rolled back.';
GO
