-- =====================================================================
-- 543  Audit Configuration owns Scope and Question Sets; review and
--      approval live there (includes 542, which never reached the repo)
--
-- REQUEST (2026-11-13, sir)
--   Scope Builder and Question Sets move from Audit Definition to Audit
--   Configuration; Audit Definition keeps only the audit details. On the
--   configuration page each step opens in its own popup and is saved
--   there. Submit for Review (and Approve) belong to this page, enabled
--   once every step is complete (542).
--
-- WHAT THIS DOES
--   1. fn_org_assurance_setup_steps -- 541 body with two changes:
--      * Scope Builder and Question Sets are configuration steps
--        (IsConfiguration = 1), so "configured" counts 6 steps.
--      * Scope Resolution is Completed only when the last resolve is not
--        older than the last scope save (scope_group.entered_dt vs
--        scope_resolution.resolved_at); a scope changed after it is
--        In progress. The chips, the list and the review gate
--        (sp_org_assurance_definition_submit, 537) all follow, so an audit
--        whose scope changed after resolving must be resolved again before
--        it can be submitted.
--   2. sp_org_assurance_configuration_list -- 537 body: lists every Draft
--      audit and every audit Under Review (Under Review first), no longer
--      only Drafts with a scope and question sets; adds ScopeStatus and
--      QuestionsStatus; ConfigurationSteps = 6.
--
-- NOT CHANGED: sp_org_assurance_setup_status (reads the function),
--   sp_org_assurance_definition_submit (537 gate already lists Scope and
--   Question Sets), the transition / approve procedures, every table,
--   the Draft-only rule of every save procedure.
--
-- DEPENDS ON: 537, 541.
-- Rollback: 543_audit_configuration_steps_rollback.sql (541 function,
--   537 list).
-- Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID('grac_practice.fn_org_assurance_setup_steps','IF') IS NULL
   OR OBJECT_ID('grac_practice.sp_org_assurance_configuration_list','P') IS NULL
   OR OBJECT_DEFINITION(OBJECT_ID('grac_practice.fn_org_assurance_setup_steps')) NOT LIKE '%scoring_ready%'
   OR COL_LENGTH('grac_practice.org_assurance_scope_group','entered_dt') IS NULL
   OR COL_LENGTH('grac_practice.org_assurance_scope_resolution','resolved_at') IS NULL
BEGIN
    PRINT 'ABORT (543): run 537 and 541 first. Nothing was changed.';
    RAISERROR('543_audit_configuration_steps: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. fn_org_assurance_setup_steps (541 body + 543 changes)
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
                                        AND b.is_active = 1))))         AS scoring_ready,
            (SELECT COUNT(*)
               FROM grac_practice.org_assurance_trigger_config t
              WHERE t.org_assurance_definition_version_id = @version_id
                AND t.organization_id = @organization_id
                AND t.is_active = 1)                                  AS trigger_rows,
            (SELECT COUNT(*)
               FROM grac_practice.org_assurance_scope_resolution r
              WHERE r.org_assurance_definition_version_id = @version_id
                AND r.organization_id = @organization_id)             AS resolutions,
            -- 543: when the scope was last saved (its groups are deleted
            -- and re-inserted on every save, 074, so entered_dt is the
            -- save time) and when it was last resolved. Both UTC.
            (SELECT MAX(g.entered_dt)
               FROM grac_practice.org_assurance_scope_group g
              WHERE g.org_assurance_definition_version_id = @version_id
                AND g.organization_id = @organization_id
                AND g.is_active = 1)                                  AS scope_saved_at,
            (SELECT MAX(r.resolved_at)
               FROM grac_practice.org_assurance_scope_resolution r
              WHERE r.org_assurance_definition_version_id = @version_id
                AND r.organization_id = @organization_id)             AS resolved_at
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
                 ELSE N'NotConfigured' END),
        (6, N'trigger',          N'Trigger',          CAST(1 AS BIT), c.trigger_rows,
            CASE WHEN c.trigger_rows > 0 THEN N'Completed' ELSE N'NotConfigured' END),
        (7, N'scope-resolution', N'Scope Resolution', CAST(1 AS BIT), c.resolutions,
            -- 543: Completed only when the last resolve is not older than
            -- the scope it resolved; a scope saved after it leaves the step
            -- In progress (resolve again). No scope: never Completed.
            CASE WHEN c.resolutions = 0 THEN N'NotConfigured'
                 WHEN c.scope_groups > 0 AND c.resolved_at >= c.scope_saved_at THEN N'Completed'
                 ELSE N'InProgress' END)
    ) AS x(StepOrder, StepKey, StepName, IsConfiguration, ItemCount, Status);
GO

-- =====================================================================
-- 2. sp_org_assurance_configuration_list (537 body + 543 changes)
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
    -- same function as the chips; all six count (IsConfiguration = 1).
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
           st.trigger_status,
           st.resolution_status,
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
               MAX(CASE WHEN f.StepKey = N'trigger'          THEN f.Status END) AS trigger_status,
               MAX(CASE WHEN f.StepKey = N'scope-resolution' THEN f.Status END) AS resolution_status,
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
           trigger_status           AS TriggerStatus,
           resolution_status        AS ScopeResolutionStatus,
           CAST(configured_steps AS INT) AS ConfiguredSteps,
           CAST(6 AS INT)           AS ConfigurationSteps,
           CAST(CASE WHEN configured_steps = 6 THEN 1 ELSE 0 END AS BIT) AS IsConfigured
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
SELECT '543 scope resolution compares with the scope save' AS Check_,
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.fn_org_assurance_setup_steps')) LIKE '%scope_saved_at%' THEN 'PASS' ELSE 'FAIL' END AS Result_
UNION ALL SELECT '543 configuration list includes Under Review',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_org_assurance_configuration_list')) LIKE '%UnderReview%' THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT '543 configuration list returns ScopeStatus',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_org_assurance_configuration_list')) LIKE '%AS ScopeStatus%' THEN 'PASS' ELSE 'FAIL' END;
PRINT '543 complete. Restart the Api and deploy Web.';
GO
SET NOEXEC OFF;
GO
