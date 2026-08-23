-- =====================================================================
-- 179 Organization SLA Config -- procedure ROLLBACK
--
-- Drops all procs defined in 179. Safe to re-run.
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.sp_ctrl_sla_master_list','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_ctrl_sla_master_list;
GO

IF OBJECT_ID('grac_practice.sp_org_sla_process_type_list','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_org_sla_process_type_list;
GO

IF OBJECT_ID('grac_practice.sp_org_sla_config_list','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_org_sla_config_list;
GO

IF OBJECT_ID('grac_practice.sp_org_sla_config_get','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_org_sla_config_get;
GO

IF OBJECT_ID('grac_practice.sp_org_sla_config_upsert','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_org_sla_config_upsert;
GO

IF OBJECT_ID('grac_practice.sp_org_sla_config_notify_role_set','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_org_sla_config_notify_role_set;
GO

IF OBJECT_ID('grac_practice.sp_org_sla_process_binding_set','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_org_sla_process_binding_set;
GO

IF OBJECT_ID('grac_practice.sp_org_sla_config_for_process','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_org_sla_config_for_process;
GO

PRINT '179 Organization SLA Config procedures rolled back.';
GO
