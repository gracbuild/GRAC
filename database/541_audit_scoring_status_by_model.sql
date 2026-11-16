-- =====================================================================
-- 541  Audit setup status -- Scoring is complete by its model type
--
-- REQUEST (2026-11-13, sir)
--   Scoring saved with data (Weighted, thresholds 80 / 60 / 59) still
--   showed "In progress".
--
-- CAUSE
--   fn_org_assurance_setup_steps (537, rule from 278) called Scoring
--   Completed only with at least one band. Pass / Fail and Weighted use
--   thresholds and have no bands (087: SupportsBands = 0), and the
--   screen saves no bands for them -- so they could never complete, and
--   Submit for Review (537 gate) would stay blocked.
--
-- WHAT THIS DOES
--   fn_org_assurance_setup_steps re-issued from 537 with one change, the
--   Scoring row: Completed when the config has what its model type uses
--   -- a Pass Threshold for PASS_FAIL / WEIGHTED / PERCENTAGE / CUSTOM,
--   or an active band for RISK_BASED / MATURITY_BASED / PERCENTAGE /
--   CUSTOM; In progress when a config exists without that. ItemCount is
--   the band count, or 1 for a complete threshold-only scoring.
--   Everything reading the function follows: the chips
--   (sp_org_assurance_setup_status), the Audit Configuration list and the
--   review gate.
-- Rollback: 541_audit_scoring_status_by_model_rollback.sql (537 body).
-- Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID('grac_practice.fn_org_assurance_setup_steps','IF') IS NULL
   OR COL_LENGTH('grac_practice.org_assurance_scoring_config','scoring_model_type') IS NULL
   OR COL_LENGTH('grac_practice.org_assurance_scoring_config','pass_threshold') IS NULL
BEGIN
    PRINT 'ABORT (541): run 537 first (fn_org_assurance_setup_steps), and 086 (scoring columns). Nothing was changed.';
    RAISERROR('541_audit_scoring_status_by_model: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
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
        (5, N'scoring',          N'Scoring',          CAST(1 AS BIT),
            CASE WHEN c.scoring_band > 0 THEN c.scoring_band ELSE c.scoring_ready END,
            CASE WHEN c.scoring_ready > 0 THEN N'Completed'
                 WHEN c.scoring_cfg  > 0 THEN N'InProgress'
                 ELSE N'NotConfigured' END),
        (6, N'trigger',          N'Trigger',          CAST(1 AS BIT), c.trigger_rows,
            CASE WHEN c.trigger_rows > 0 THEN N'Completed' ELSE N'NotConfigured' END),
        (7, N'scope-resolution', N'Scope Resolution', CAST(1 AS BIT), c.resolutions,
            CASE WHEN c.resolutions  > 0 THEN N'Completed' ELSE N'NotConfigured' END)
    ) AS x(StepOrder, StepKey, StepName, IsConfiguration, ItemCount, Status);
GO

SELECT '541 Scoring step follows the model type' AS Check_,
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.fn_org_assurance_setup_steps')) LIKE '%scoring_ready%'
            THEN 'PASS' ELSE 'FAIL' END AS Result_;
PRINT '541 complete. No restart needed; reload the page.';
GO
SET NOEXEC OFF;
GO
