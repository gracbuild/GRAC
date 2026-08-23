-- =====================================================================
-- 067 Workflow & Event-Driven Assurance Engine procedures -- ROLLBACK
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.sp_workflow_dashboard_counts','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_workflow_dashboard_counts;
GO
IF OBJECT_ID('grac_practice.sp_event_gap_close','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_event_gap_close;
GO
IF OBJECT_ID('grac_practice.sp_event_gap_open','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_event_gap_open;
GO
IF OBJECT_ID('grac_practice.sp_event_gap_list','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_event_gap_list;
GO
IF OBJECT_ID('grac_practice.sp_event_instance_item_save','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_event_instance_item_save;
GO
IF OBJECT_ID('grac_practice.sp_event_instance_complete','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_event_instance_complete;
GO
IF OBJECT_ID('grac_practice.sp_event_instance_trigger','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_event_instance_trigger;
GO
IF OBJECT_ID('grac_practice.sp_event_instance_list','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_event_instance_list;
GO
IF OBJECT_ID('grac_practice.sp_event_checklist_mapping_save','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_event_checklist_mapping_save;
GO
IF OBJECT_ID('grac_practice.sp_event_checklist_mapping_list','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_event_checklist_mapping_list;
GO
IF OBJECT_ID('grac_practice.sp_checklist_item_save','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_checklist_item_save;
GO
IF OBJECT_ID('grac_practice.sp_checklist_item_list','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_checklist_item_list;
GO
IF OBJECT_ID('grac_practice.sp_checklist_save','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_checklist_save;
GO
IF OBJECT_ID('grac_practice.sp_checklist_list','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_checklist_list;
GO
IF OBJECT_ID('grac_practice.sp_event_definition_save','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_event_definition_save;
GO
IF OBJECT_ID('grac_practice.sp_event_definition_list','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_event_definition_list;
GO
IF OBJECT_ID('grac_practice.sp_entity_type_save','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_entity_type_save;
GO
IF OBJECT_ID('grac_practice.sp_entity_type_list','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_entity_type_list;
GO
IF OBJECT_ID('grac_practice.sp_workflow_stage_save','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_workflow_stage_save;
GO
IF OBJECT_ID('grac_practice.sp_workflow_stage_list','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_workflow_stage_list;
GO
IF OBJECT_ID('grac_practice.sp_workflow_save','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_workflow_save;
GO
IF OBJECT_ID('grac_practice.sp_workflow_list','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_workflow_list;
GO

PRINT '067 workflow engine procedures rollback complete.';
GO
