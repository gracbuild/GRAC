-- =====================================================================
-- 537 ROLLBACK  Audit Configuration list + review gate
--   Restores sp_org_assurance_setup_status (536 body),
--   sp_org_assurance_definition_submit (070 body), and drops
--   sp_org_assurance_configuration_list and fn_org_assurance_setup_steps.
--   Revert the Api / Web files with it. ASCII-only. Re-runnable.
-- =====================================================================
SET NOCOUNT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_setup_status
    @organization_id BIGINT,
    @definition_id   BIGINT,
    @version_id      BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL OR @definition_id IS NULL
        THROW 53602, 'organization_id and definition_id are required.', 1;

    DECLARE @def_org BIGINT, @current_version_id BIGINT, @current_status_code NVARCHAR(60);

    SELECT @def_org             = d.organization_id,
           @current_version_id  = d.current_version_id,
           @current_status_code = s.status_code
    FROM grac_practice.org_assurance_definition d
    JOIN grac_practice.org_assurance_status_master s
         ON s.org_assurance_status_id = d.current_status_id
    WHERE d.org_assurance_definition_id = @definition_id
      AND d.is_active = 1;

    IF @def_org IS NULL      THROW 53606, 'Definition not found.', 1;
    IF @def_org <> @organization_id
        THROW 53607, 'Definition belongs to a different organization.', 1;

    IF @version_id IS NULL SET @version_id = @current_version_id;

    DECLARE @scope_groups   INT = 0,
            @question_sets  INT = 0,
            @workflow_cfg   INT = 0,
            @workflow_stage INT = 0,
            @scoring_cfg    INT = 0,
            @scoring_band   INT = 0,
            @trigger_rows   INT = 0,
            @resolutions    INT = 0;

    SELECT @scope_groups = COUNT(*)
      FROM grac_practice.org_assurance_scope_group g
     WHERE g.org_assurance_definition_version_id = @version_id
       AND g.organization_id = @organization_id
       AND g.is_active = 1;

    SELECT @question_sets = COUNT(*)
      FROM grac_practice.org_assurance_definition_question_set q
     WHERE q.org_assurance_definition_version_id = @version_id
       AND q.organization_id = @organization_id
       AND q.is_active = 1;

    -- 536: no Evidence step -- Evidence Config is retired; evidence is
    -- set per question in the question sets.

    SELECT @workflow_cfg = COUNT(*)
      FROM grac_practice.org_assurance_workflow_config w
     WHERE w.org_assurance_definition_version_id = @version_id
       AND w.organization_id = @organization_id
       AND w.is_active = 1;

    SELECT @workflow_stage = COUNT(*)
      FROM grac_practice.org_assurance_workflow_stage st
      JOIN grac_practice.org_assurance_workflow_config w
           ON w.org_assurance_workflow_config_id = st.org_assurance_workflow_config_id
     WHERE w.org_assurance_definition_version_id = @version_id
       AND w.organization_id = @organization_id
       AND w.is_active = 1
       AND st.is_active = 1;

    SELECT @scoring_cfg = COUNT(*)
      FROM grac_practice.org_assurance_scoring_config sc
     WHERE sc.org_assurance_definition_version_id = @version_id
       AND sc.organization_id = @organization_id
       AND sc.is_active = 1;

    SELECT @scoring_band = COUNT(*)
      FROM grac_practice.org_assurance_scoring_band b
      JOIN grac_practice.org_assurance_scoring_config sc
           ON sc.org_assurance_scoring_config_id = b.org_assurance_scoring_config_id
     WHERE sc.org_assurance_definition_version_id = @version_id
       AND sc.organization_id = @organization_id
       AND sc.is_active = 1
       AND b.is_active  = 1;

    SELECT @trigger_rows = COUNT(*)
      FROM grac_practice.org_assurance_trigger_config t
     WHERE t.org_assurance_definition_version_id = @version_id
       AND t.organization_id = @organization_id
       AND t.is_active = 1;

    SELECT @resolutions = COUNT(*)
      FROM grac_practice.org_assurance_scope_resolution r
     WHERE r.org_assurance_definition_version_id = @version_id
       AND r.organization_id = @organization_id;

    -- Header, so the caller knows which version was measured.
    SELECT @definition_id       AS DefinitionId,
           @version_id          AS VersionId,
           @current_version_id  AS CurrentVersionId,
           @current_status_code AS CurrentStatusCode,
           CAST(CASE WHEN @current_status_code = N'Draft'
                     AND @version_id = @current_version_id
                     THEN 1 ELSE 0 END AS BIT) AS IsEditable;

    -- One row per step. "details" is Completed by definition: the audit
    -- exists and has a version, or this procedure would have thrown.
    SELECT StepKey, StepName, ItemCount, Status
    FROM (VALUES
        (N'details',          N'Audit Details',      1,
            N'Completed'),
        (N'scope',            N'Scope Builder',      @scope_groups,
            CASE WHEN @scope_groups  > 0 THEN N'Completed' ELSE N'NotConfigured' END),
        (N'questions',        N'Question Sets',      @question_sets,
            CASE WHEN @question_sets > 0 THEN N'Completed' ELSE N'NotConfigured' END),
        (N'workflow',         N'Workflow',           @workflow_stage,
            CASE WHEN @workflow_stage > 0 THEN N'Completed'
                 WHEN @workflow_cfg   > 0 THEN N'InProgress'
                 ELSE N'NotConfigured' END),
        (N'scoring',          N'Scoring',            @scoring_band,
            CASE WHEN @scoring_cfg  > 0 AND @scoring_band > 0 THEN N'Completed'
                 WHEN @scoring_cfg  > 0 THEN N'InProgress'
                 ELSE N'NotConfigured' END),
        (N'trigger',          N'Trigger',            @trigger_rows,
            CASE WHEN @trigger_rows > 0 THEN N'Completed' ELSE N'NotConfigured' END),
        (N'scope-resolution', N'Scope Resolution',   @resolutions,
            CASE WHEN @resolutions  > 0 THEN N'Completed' ELSE N'NotConfigured' END)
    ) AS x(StepKey, StepName, ItemCount, Status);
END
GO
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_definition_submit
    @organization_id BIGINT,
    @definition_id   BIGINT,
    @reason_text     NVARCHAR(1000) = NULL,
    @actor           NVARCHAR(100)  = 'system'
AS
BEGIN
    SET NOCOUNT ON;
    EXEC grac_practice.sp_org_assurance_definition_transition
        @organization_id    = @organization_id,
        @definition_id      = @definition_id,
        @expected_from_code = N'Draft',
        @to_code            = N'UnderReview',
        @action_code        = N'SUBMIT',
        @reason_text        = @reason_text,
        @actor              = @actor;
END
GO
IF OBJECT_ID('grac_practice.sp_org_assurance_configuration_list','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_org_assurance_configuration_list;
GO
IF OBJECT_ID('grac_practice.fn_org_assurance_setup_steps','IF') IS NOT NULL
    DROP FUNCTION grac_practice.fn_org_assurance_setup_steps;
GO
PRINT 'ROLLBACK 537 complete.';
GO
