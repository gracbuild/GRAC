-- =====================================================================
-- 538  Audit Workflow: a chosen Admin template brings its stages
--
-- REQUEST (2026-11-13, sir)
--   Audit Configuration -> Workflow has "Workflow Template (Admin
--   published, optional)", but picking one only stored its id / code /
--   name on the workflow (084) -- no stage came with it, so the picker
--   did nothing useful. Picking a template must fill the stages.
--
-- THE ADMIN TABLES (grac_new, GRAC Admin -- confirmed by sir's column
-- listing, 2026-11-13; read-only here, never written)
--   assurance_workflow_template : workflow_template_id, template_code,
--     template_name, description, sla_hours, escalation_rule, version_no,
--     lifecycle_status, status
--   assurance_workflow_stage    : workflow_stage_id, workflow_template_id,
--     stage_order, stage_name, stage_type, approval_rule, escalation_rule,
--     sla_hours, status
--
-- WHAT THIS DOES
--   sp_org_assurance_admin_workflow_template_stage_list(@template_id) --
--   NEW, read-only. Two result sets:
--     1. the template: Id, Code, Name, Description, TotalSlaDays
--     2. its Active stages in stage_order, in the shape of an
--        organization workflow stage: StageOrder, StageCode, StageName,
--        StageType, SlaDays, Instructions, plus AdminStageType / SlaHours
--        as published.
--   Mapping (the organization's stage is the customized copy, 083):
--     * stage_type -> AUDITOR / REVIEWER / APPROVER when it reads as one
--       (AUDIT / AUDITOR, REVIEW / REVIEWER, APPROVE / APPROVAL /
--       APPROVER, any case); anything else -> CUSTOM, its published name
--       kept in Instructions.
--     * sla_hours -> days, rounded up (org SLAs are in days).
--     * approval_rule / escalation_rule (free text) -> Instructions, as
--       labelled lines; escalation role and days stay for the org to pick.
--     * StageCode STG-01, STG-02 ... by order (org stage_code is NOT NULL
--       and the Admin stage has no code).
--     * Roles and employees are organization data -- left empty.
--   Nothing is copied by this procedure: the Workflow screen fills its
--   stage grid from it, and the existing save (084) writes them.
--
-- NOT CHANGED: sp_org_assurance_admin_workflow_template_list (084), the
--   workflow save / get, every table.
-- Rollback: 538_audit_workflow_template_stages_rollback.sql
-- Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

DECLARE @missing NVARCHAR(MAX) = N'';
IF OBJECT_ID('grac_new.assurance_workflow_template','U') IS NULL SET @missing += N' table grac_new.assurance_workflow_template;';
IF OBJECT_ID('grac_new.assurance_workflow_stage','U') IS NULL    SET @missing += N' table grac_new.assurance_workflow_stage;';
IF @missing = N''
BEGIN
    IF COL_LENGTH('grac_new.assurance_workflow_template','template_code') IS NULL
       OR COL_LENGTH('grac_new.assurance_workflow_template','template_name') IS NULL
       OR COL_LENGTH('grac_new.assurance_workflow_template','sla_hours') IS NULL
       OR COL_LENGTH('grac_new.assurance_workflow_template','description') IS NULL
        SET @missing += N' assurance_workflow_template columns template_code / template_name / description / sla_hours;';
    IF COL_LENGTH('grac_new.assurance_workflow_stage','workflow_template_id') IS NULL
       OR COL_LENGTH('grac_new.assurance_workflow_stage','stage_order') IS NULL
       OR COL_LENGTH('grac_new.assurance_workflow_stage','stage_name') IS NULL
       OR COL_LENGTH('grac_new.assurance_workflow_stage','stage_type') IS NULL
       OR COL_LENGTH('grac_new.assurance_workflow_stage','approval_rule') IS NULL
       OR COL_LENGTH('grac_new.assurance_workflow_stage','escalation_rule') IS NULL
       OR COL_LENGTH('grac_new.assurance_workflow_stage','sla_hours') IS NULL
       OR COL_LENGTH('grac_new.assurance_workflow_stage','status') IS NULL
        SET @missing += N' assurance_workflow_stage columns;';
END
IF @missing <> N''
BEGIN
    PRINT 'ABORT (538): missing --' + @missing + ' Nothing was changed.';
    RAISERROR('538_audit_workflow_template_stages: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_admin_workflow_template_stage_list
    @template_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF @template_id IS NULL
        THROW 53602, 'template_id is required.', 1;

    -- 1. The template.
    SELECT t.workflow_template_id                         AS Id,
           t.template_code                                AS Code,
           t.template_name                                AS Name,
           t.description                                  AS Description,
           CAST(CEILING(t.sla_hours / 24.0) AS INT)       AS TotalSlaDays
      FROM grac_new.assurance_workflow_template t
     WHERE t.workflow_template_id = @template_id;

    -- 2. Its Active stages, shaped as organization stages.
    SELECT ROW_NUMBER() OVER (ORDER BY s.stage_order, s.workflow_stage_id) AS StageOrder,
           N'STG-' + RIGHT(N'0' + CAST(ROW_NUMBER() OVER (ORDER BY s.stage_order, s.workflow_stage_id) AS NVARCHAR(10)), 2)
                                                          AS StageCode,
           LEFT(s.stage_name, 200)                        AS StageName,
           x.stage_type                                   AS StageType,
           CAST(CEILING(s.sla_hours / 24.0) AS INT)       AS SlaDays,
           NULLIF(CONCAT_WS(CHAR(13) + CHAR(10),
                CASE WHEN x.stage_type = N'CUSTOM' AND NULLIF(LTRIM(RTRIM(s.stage_type)), N'') IS NOT NULL
                     THEN N'Stage type (template): ' + LTRIM(RTRIM(s.stage_type)) END,
                CASE WHEN NULLIF(LTRIM(RTRIM(s.approval_rule)), N'') IS NOT NULL
                     THEN N'Approval rule: ' + LTRIM(RTRIM(s.approval_rule)) END,
                CASE WHEN NULLIF(LTRIM(RTRIM(s.escalation_rule)), N'') IS NOT NULL
                     THEN N'Escalation rule: ' + LTRIM(RTRIM(s.escalation_rule)) END), N'')
                                                          AS Instructions,
           s.stage_type                                   AS AdminStageType,
           s.sla_hours                                    AS SlaHours
      FROM grac_new.assurance_workflow_stage s
     CROSS APPLY (SELECT CASE UPPER(LTRIM(RTRIM(s.stage_type)))
                             WHEN N'AUDIT'    THEN N'AUDITOR'
                             WHEN N'AUDITOR'  THEN N'AUDITOR'
                             WHEN N'REVIEW'   THEN N'REVIEWER'
                             WHEN N'REVIEWER' THEN N'REVIEWER'
                             WHEN N'APPROVE'  THEN N'APPROVER'
                             WHEN N'APPROVAL' THEN N'APPROVER'
                             WHEN N'APPROVER' THEN N'APPROVER'
                             ELSE N'CUSTOM' END AS stage_type) x
     WHERE s.workflow_template_id = @template_id
       AND s.status = N'Active'
     ORDER BY s.stage_order, s.workflow_stage_id;
END
GO

SELECT '538 sp_org_assurance_admin_workflow_template_stage_list exists' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.sp_org_assurance_admin_workflow_template_stage_list','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result_;
PRINT '538 complete. Restart the Api and deploy Web.';
GO
SET NOEXEC OFF;
GO
