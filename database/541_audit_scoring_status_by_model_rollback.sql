-- =====================================================================
-- 541 ROLLBACK -- fn_org_assurance_setup_steps back to its 537 body
-- (Scoring Completed only with bands). ASCII-only. Re-runnable.
-- =====================================================================
SET NOCOUNT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
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
            (SELECT COUNT(*)
               FROM grac_practice.org_assurance_trigger_config t
              WHERE t.org_assurance_definition_version_id = @version_id
                AND t.organization_id = @organization_id
                AND t.is_active = 1)                                  AS trigger_rows,
            (SELECT COUNT(*)
               FROM grac_practice.org_assurance_scope_resolution r
              WHERE r.org_assurance_definition_version_id = @version_id
                AND r.organization_id = @organization_id)             AS resolutions
    )
    SELECT x.StepOrder, x.StepKey, x.StepName, x.IsConfiguration, x.ItemCount, x.Status
    FROM c
    CROSS APPLY (VALUES
        (1, N'details',          N'Audit Details',    CAST(0 AS BIT), 1,
            N'Completed'),
        (2, N'scope',            N'Scope Builder',    CAST(0 AS BIT), c.scope_groups,
            CASE WHEN c.scope_groups  > 0 THEN N'Completed' ELSE N'NotConfigured' END),
        (3, N'questions',        N'Question Sets',    CAST(0 AS BIT), c.question_sets,
            CASE WHEN c.question_sets > 0 THEN N'Completed' ELSE N'NotConfigured' END),
        (4, N'workflow',         N'Workflow',         CAST(1 AS BIT), c.workflow_stage,
            CASE WHEN c.workflow_stage > 0 THEN N'Completed'
                 WHEN c.workflow_cfg   > 0 THEN N'InProgress'
                 ELSE N'NotConfigured' END),
        (5, N'scoring',          N'Scoring',          CAST(1 AS BIT), c.scoring_band,
            CASE WHEN c.scoring_cfg  > 0 AND c.scoring_band > 0 THEN N'Completed'
                 WHEN c.scoring_cfg  > 0 THEN N'InProgress'
                 ELSE N'NotConfigured' END),
        (6, N'trigger',          N'Trigger',          CAST(1 AS BIT), c.trigger_rows,
            CASE WHEN c.trigger_rows > 0 THEN N'Completed' ELSE N'NotConfigured' END),
        (7, N'scope-resolution', N'Scope Resolution', CAST(1 AS BIT), c.resolutions,
            CASE WHEN c.resolutions  > 0 THEN N'Completed' ELSE N'NotConfigured' END)
    ) AS x(StepOrder, StepKey, StepName, IsConfiguration, ItemCount, Status);
GO
PRINT 'ROLLBACK 541 complete.';
GO
