-- =====================================================================
-- 093 Organization Assurance Trigger procedures rollback
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.sp_org_assurance_trigger_delete','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_trigger_delete;
GO
IF OBJECT_ID('grac_practice.sp_org_assurance_trigger_save','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_trigger_save;
GO
IF OBJECT_ID('grac_practice.sp_org_assurance_trigger_get','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_trigger_get;
GO
IF OBJECT_ID('grac_practice.sp_org_assurance_trigger_list','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_trigger_list;
GO
IF OBJECT_ID('grac_practice.sp_org_assurance_continuous_source_list','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_continuous_source_list;
GO
IF OBJECT_ID('grac_practice.sp_org_assurance_event_code_list','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_event_code_list;
GO
IF OBJECT_ID('grac_practice.sp_org_assurance_schedule_frequency_list','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_schedule_frequency_list;
GO
IF OBJECT_ID('grac_practice.sp_org_assurance_trigger_type_list','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_trigger_type_list;
GO

PRINT '093 rollback complete.';
GO
