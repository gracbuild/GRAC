-- =====================================================================
-- 066 Workflow & Event-Driven Assurance Engine schema -- ROLLBACK
-- Drops tables in reverse-dependency order.
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.event_audit','U') IS NOT NULL
    DROP TABLE grac_practice.event_audit;
GO

IF OBJECT_ID('grac_practice.event_gap','U') IS NOT NULL
    DROP TABLE grac_practice.event_gap;
GO

IF OBJECT_ID('grac_practice.event_instance_item','U') IS NOT NULL
    DROP TABLE grac_practice.event_instance_item;
GO

IF OBJECT_ID('grac_practice.event_instance','U') IS NOT NULL
    DROP TABLE grac_practice.event_instance;
GO

IF OBJECT_ID('grac_practice.event_checklist_mapping','U') IS NOT NULL
    DROP TABLE grac_practice.event_checklist_mapping;
GO

IF OBJECT_ID('grac_practice.checklist_item','U') IS NOT NULL
    DROP TABLE grac_practice.checklist_item;
GO

IF OBJECT_ID('grac_practice.checklist','U') IS NOT NULL
    DROP TABLE grac_practice.checklist;
GO

IF OBJECT_ID('grac_practice.event_definition','U') IS NOT NULL
    DROP TABLE grac_practice.event_definition;
GO

IF OBJECT_ID('grac_practice.entity_type_master','U') IS NOT NULL
    DROP TABLE grac_practice.entity_type_master;
GO

IF OBJECT_ID('grac_practice.workflow_stage','U') IS NOT NULL
    DROP TABLE grac_practice.workflow_stage;
GO

IF OBJECT_ID('grac_practice.workflow','U') IS NOT NULL
    DROP TABLE grac_practice.workflow;
GO

PRINT '066 workflow engine schema rollback complete.';
GO
