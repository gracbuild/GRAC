-- =====================================================================
-- 548  Trigger is no longer an Audit Configuration step
--
-- REQUEST (2026-11-14, sir)
--   "remove the trigger option from configuration." Nothing runs an audit
--   from a trigger (no scheduler / event listener reads
--   org_assurance_trigger_config); executions start from plan slots (546).
--   The step only saved data yet blocked Submit for Review.
--
-- WHAT THIS DOES
--   1. fn_org_assurance_setup_steps (545 body): the Trigger step is
--      removed -- four configuration steps (Scope Builder, Question Sets,
--      Workflow, Scoring). The chips, the Audit Configuration list and the
--      537 review gate (sp_org_assurance_definition_submit reads this
--      function) follow: Submit for Review no longer needs a trigger.
--   2. sp_org_assurance_configuration_list (545 body): no TriggerStatus;
--      ConfigurationSteps = 4.
--
-- NOT CHANGED: org_assurance_trigger_config and its rows, the trigger
--   procedures and endpoints, execution origin TRIGGER, the submit
--   procedure itself.
-- DEPENDS ON: 545.
-- Rollback: 548_audit_trigger_step_removed_rollback.sql (545 function and
--   list).
-- Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID('grac_practice.fn_org_assurance_setup_steps','IF') IS NULL
   OR OBJECT_ID('grac_practice.sp_org_assurance_configuration_list','P') IS NULL
   OR OBJECT_DEFINITION(OBJECT_ID('grac_practice.fn_org_assurance_setup_steps')) LIKE '%scope-resolution%'
BEGIN
    PRINT 'ABORT (548): run 545 first. Nothing was changed.';
    RAISERROR('548_audit_trigger_step_removed: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. fn_org_assurance_setup_steps (545 body, no Trigger step)
-- =====================================================================
CREATE OR ALTER FUNCTION grac_practice.fn_org_assurance_setup_steps
(
    @organization_id BIGINT,
    @version_id      BIGINT
)
RETURNS TABLE
AS
RETURN
    WITH c AS (
        SELECT
            (SELECT COUNT(*)
               FROM grac_practice.org_assurance_scope_group g
              WHERE g.org_assurance_definition_version_id = @version_id
                AND g.organization_id = @organization_id
                AND g.is_active = 1)                                  AS scope_groups,
            (SELECT COUNT(*)
               FROM grac_practice.org_assurance_definition_question_set q
              WHERE q.org_assurance_definition_version_id = @version_id
                AND q.organization_id = @organization_id
                AND q.is_active = 1)                                  AS question_sets,
            (SELECT COUNT(*)
               FROM grac_practice.org_assurance_workflow_config w
              WHERE w.org_assurance_definition_version_id = @version_id
                AND w.organization_id = @organization_id
                AND w.is_active = 1)                                  AS workflow_cfg,
            (SELECT COUNT(*)
               FROM grac_practice.org_assurance_workflow_stage st
               JOIN grac_practice.org_assurance_workflow_config w
                    ON w.org_assurance_workflow_config_id = st.org_assurance_workflow_config_id
              WHERE w.org_assurance_definition_version_id = @version_id
                AND w.organization_id = @organization_id
                AND w.is_active = 1
                AND st.is_active = 1)                                 AS workflow_stage,
            (SELECT COUNT(*)
               FROM grac_practice.org_assurance_scoring_config sc
              WHERE sc.org_assurance_definition_version_id = @version_id
                AND sc.organization_id = @organization_id
                AND sc.is_active = 1)                                 AS scoring_cfg,
            (SELECT COUNT(*)
               FROM grac_practice.org_assurance_scoring_band b
               JOIN grac_practice.org_assurance_scoring_config sc
                    ON sc.org_assurance_scoring_config_id = b.org_assurance_scoring_config_id
              WHERE sc.org_assurance_definition_version_id = @version_id
                AND sc.organization_id = @organization_id
                AND sc.is_active = 1
                AND b.is_active  = 1)                                 AS scoring_band,
            -- 541: a scoring config is complete when it has what its model
            -- type uses (087 sp_org_assurance_scoring_model_type_list):
            --   thresholds (SupportsThreshold): PASS_FAIL, WEIGHTED,
            --     PERCENTAGE, CUSTOM -> a Pass Threshold;
            --   bands (SupportsBands): RISK_BASED, MATURITY_BASED,
            --     PERCENTAGE, CUSTOM -> at least one active band.
            -- Before 541 every type needed bands, so a Weighted or Pass /
            -- Fail scoring (thresholds only) never left "In progress".
            (SELECT COUNT(*)
               FROM grac_practice.org_assurance_scoring_config sc
              WHERE sc.org_assurance_definition_version_id = @version_id
                AND sc.organization_id = @organization_id
                AND sc.is_active = 1
                AND (   (sc.scoring_model_type IN (N'PASS_FAIL', N'WEIGHTED', N'PERCENTAGE', N'CUSTOM')
                         AND sc.pass_threshold IS NOT NULL)
                     OR (sc.scoring_model_type IN (N'RISK_BASED', N'MATURITY_BASED', N'PERCENTAGE', N'CUSTOM')
                         AND EXISTS (SELECT 1
                                       FROM grac_practice.org_assurance_scoring_band b
                                      WHERE b.org_assurance_scoring_config_id = sc.org_assurance_scoring_config_id
                                        AND b.is_active = 1))))         AS scoring_ready
            -- 548: no Trigger step -- executions start from plan slots (546);
            -- nothing runs an audit from a trigger.
            -- 545: no Scope Resolution step -- the scope is resolved when
            -- an execution is created (sp_org_assurance_execution_materialize).
    )
    SELECT x.StepOrder, x.StepKey, x.StepName, x.IsConfiguration, x.ItemCount, x.Status
    FROM c
    CROSS APPLY (VALUES
        (1, N'details',          N'Audit Details',    CAST(0 AS BIT), 1,
            N'Completed'),
        (2, N'scope',            N'Scope Builder',    CAST(1 AS BIT), c.scope_groups,
            CASE WHEN c.scope_groups  > 0 THEN N'Completed' ELSE N'NotConfigured' END),
        (3, N'questions',        N'Question Sets',    CAST(1 AS BIT), c.question_sets,
            CASE WHEN c.question_sets > 0 THEN N'Completed' ELSE N'NotConfigured' END),
        (4, N'workflow',         N'Workflow',         CAST(1 AS BIT), c.workflow_stage,
            CASE WHEN c.workflow_stage > 0 THEN N'Completed'
                 WHEN c.workflow_cfg   > 0 THEN N'InProgress'
                 ELSE N'NotConfigured' END),
        (5, N'scoring',          N'Scoring',          CAST(1 AS BIT),
            CASE WHEN c.scoring_band > 0 THEN c.scoring_band ELSE c.scoring_ready END,
            CASE WHEN c.scoring_ready > 0 THEN N'Completed'
                 WHEN c.scoring_cfg  > 0 THEN N'InProgress'
                 ELSE N'NotConfigured' END)
    ) AS x(StepOrder, StepKey, StepName, IsConfiguration, ItemCount, Status);
GO

-- =====================================================================
-- 2. sp_org_assurance_configuration_list (545 body, four steps)
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_configuration_list
    @organization_id BIGINT,
    @search          NVARCHAR(200) = NULL,
    @page            INT = 1,
    @page_size       INT = 25
AS
BEGIN
    SET NOCOUNT ON;

    IF @organization_id IS NULL
        THROW 53601, 'organization_id is required.', 1;
    IF @page IS NULL OR @page < 1           SET @page = 1;
    IF @page_size IS NULL OR @page_size < 1 SET @page_size = 25;
    IF @page_size > 200                     SET @page_size = 200;

    DECLARE @offset INT = (@page - 1) * @page_size;

    -- 543: every Draft audit (Scope and Question Sets are configured on
    -- this page now, so a Draft with neither must be listed) and every
    -- audit Under Review (approved from this page). Steps come from the
    -- same function as the chips; all four count (IsConfiguration = 1;
    -- 548: Scope Builder, Question Sets, Workflow, Scoring).
    SELECT d.org_assurance_definition_id AS definition_id,
           d.organization_id,
           d.definition_code,
           d.definition_name,
           d.owner_role_name,
           d.owner_display_name,
           d.current_version_id,
           s.status_code               AS current_status_code,
           s.status_name               AS current_status_name,
           v.version_number            AS current_version_number,
           v.version_label             AS current_version_label,
           v.effective_date            AS current_effective_date,
           v.assurance_category_name   AS current_category_name,
           st.scope_status,
           st.questions_status,
           st.workflow_status,
           st.scoring_status,
           st.configured_steps,
           d.updated_dt
    INTO #cfg
    FROM grac_practice.org_assurance_definition d
    JOIN grac_practice.org_assurance_status_master s
         ON s.org_assurance_status_id = d.current_status_id
    LEFT JOIN grac_practice.org_assurance_definition_version v
         ON v.org_assurance_definition_version_id = d.current_version_id
    CROSS APPLY (
        SELECT MAX(CASE WHEN f.StepKey = N'scope'            THEN f.Status END) AS scope_status,
               MAX(CASE WHEN f.StepKey = N'questions'        THEN f.Status END) AS questions_status,
               MAX(CASE WHEN f.StepKey = N'workflow'         THEN f.Status END) AS workflow_status,
               MAX(CASE WHEN f.StepKey = N'scoring'          THEN f.Status END) AS scoring_status,
               SUM(CASE WHEN f.IsConfiguration = 1 AND f.Status = N'Completed' THEN 1 ELSE 0 END) AS configured_steps
        FROM grac_practice.fn_org_assurance_setup_steps(d.organization_id, d.current_version_id) f
    ) st
    WHERE d.organization_id = @organization_id
      AND d.is_active = 1
      AND d.current_version_id IS NOT NULL
      AND s.status_code IN (N'Draft', N'UnderReview')
      AND (@search IS NULL OR @search = N''
           OR d.definition_name LIKE N'%' + @search + N'%'
           OR d.definition_code LIKE N'%' + @search + N'%');

    SELECT CAST(COUNT_BIG(1) AS BIGINT) AS TotalCount,
           CAST(@page      AS INT)      AS PageNumber,
           CAST(@page_size AS INT)      AS PageSize
    FROM #cfg;

    SELECT definition_id            AS DefinitionId,
           organization_id          AS OrganizationId,
           definition_code          AS DefinitionCode,
           definition_name          AS DefinitionName,
           owner_role_name          AS OwnerRoleName,
           owner_display_name       AS OwnerDisplayName,
           current_version_id       AS CurrentVersionId,
           current_status_code      AS CurrentStatusCode,
           current_status_name      AS CurrentStatusName,
           current_version_number   AS CurrentVersionNumber,
           current_version_label    AS CurrentVersionLabel,
           current_effective_date   AS CurrentEffectiveDate,
           current_category_name    AS CurrentCategoryName,
           scope_status             AS ScopeStatus,
           questions_status         AS QuestionsStatus,
           workflow_status          AS WorkflowStatus,
           scoring_status           AS ScoringStatus,
           CAST(configured_steps AS INT) AS ConfiguredSteps,
           CAST(4 AS INT)           AS ConfigurationSteps,   -- 548: no Trigger step
           CAST(CASE WHEN configured_steps = 4 THEN 1 ELSE 0 END AS BIT) AS IsConfigured
    FROM #cfg
    -- Under Review first: they wait on an approver.
    ORDER BY CASE WHEN current_status_code = N'UnderReview' THEN 0 ELSE 1 END,
             definition_name, definition_id
    OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
END
GO

-- =====================================================================
-- Verification
-- =====================================================================
SELECT '548 no Trigger step' AS Check_,
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.fn_org_assurance_setup_steps')) NOT LIKE '%trigger_config%' THEN 'PASS' ELSE 'FAIL' END AS Result_
UNION ALL SELECT '548 configuration list counts four steps',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_org_assurance_configuration_list')) NOT LIKE '%TriggerStatus%' THEN 'PASS' ELSE 'FAIL' END;
PRINT '548 complete. Restart the Api and publish Web.';
GO
SET NOEXEC OFF;
GO
