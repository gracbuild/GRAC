-- =====================================================================
-- 537  Audit Configuration -- a list of audits ready to configure, and
--      no review before the configuration is complete
--
-- REQUEST (2026-11-13, sir)
--   Audit Configuration showed two Organization pickers (the page's
--   context bar and each hosted screen's own). Make it a list instead:
--   the audits to configure, 3-dot menu to configure them, row click
--   opens a view whose Actions configure it. Workflow / Scoring / Trigger
--   stay Draft-only (084 / 087 / 093), so the list is the Draft audits
--   set up "up to the question sets", and Submit for Review is allowed
--   only once the configuration is done.
--
-- WHAT THIS DOES
--   1. fn_org_assurance_setup_steps(@organization_id, @version_id) --
--      inline function: one row per setup step (StepOrder, StepKey,
--      StepName, IsConfiguration, ItemCount, Status). The step rules are
--      the 278 / 536 rules, moved here unchanged so the chips, the list
--      and the review gate share one definition.
--   2. sp_org_assurance_setup_status -- 536 body, its step rows now read
--      from the function. Same two result sets, same columns.
--   3. sp_org_assurance_configuration_list -- NEW. Draft audits of an
--      organization whose current version has a Scope and at least one
--      Question Set, with Workflow / Scoring / Trigger / Scope Resolution
--      status, ConfiguredSteps of 4 and IsConfigured. COUNT header then
--      rows, paged, like sp_org_assurance_definition_list.
--   4. sp_org_assurance_definition_submit -- 070 body plus a gate: THROW
--      53612 naming the steps that are not Completed (Scope, Question
--      Sets, Workflow, Scoring, Trigger, Scope Resolution).
--
-- NOT CHANGED: the Draft-only rule of the config save procedures, the
--   transition procedure, approve / activate / retire, every table.
--
-- DEPENDS ON: 070, 084, 087, 093, 095 (scope resolution), 277, 278, 536.
-- Rollback: 537_audit_configuration_list_rollback.sql
-- Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

DECLARE @missing NVARCHAR(MAX) = N'';
IF OBJECT_ID('grac_practice.sp_org_assurance_setup_status','P') IS NULL SET @missing += N' proc sp_org_assurance_setup_status (278);';
IF OBJECT_ID('grac_practice.sp_org_assurance_definition_transition','P') IS NULL SET @missing += N' proc sp_org_assurance_definition_transition (070);';
IF OBJECT_ID('grac_practice.org_assurance_definition_question_set','U') IS NULL SET @missing += N' table org_assurance_definition_question_set (277);';
IF OBJECT_ID('grac_practice.org_assurance_scope_group','U') IS NULL SET @missing += N' table org_assurance_scope_group;';
IF OBJECT_ID('grac_practice.org_assurance_workflow_config','U') IS NULL
   OR OBJECT_ID('grac_practice.org_assurance_workflow_stage','U') IS NULL SET @missing += N' workflow tables (083);';
IF OBJECT_ID('grac_practice.org_assurance_scoring_config','U') IS NULL
   OR OBJECT_ID('grac_practice.org_assurance_scoring_band','U') IS NULL SET @missing += N' scoring tables (086);';
IF OBJECT_ID('grac_practice.org_assurance_trigger_config','U') IS NULL SET @missing += N' table org_assurance_trigger_config;';
IF OBJECT_ID('grac_practice.org_assurance_scope_resolution','U') IS NULL SET @missing += N' table org_assurance_scope_resolution;';
IF COL_LENGTH('grac_practice.org_assurance_definition_version','assurance_category_name') IS NULL SET @missing += N' org_assurance_definition_version.assurance_category_name;';
IF COL_LENGTH('grac_practice.org_assurance_definition','owner_display_name') IS NULL SET @missing += N' org_assurance_definition.owner_display_name (119);';
IF OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_org_assurance_setup_status')) LIKE '%org_assurance_evidence_config%'
    SET @missing += N' run 536 first (setup status still has the Evidence step);';
IF @missing <> N''
BEGIN
    PRINT 'ABORT (537): missing --' + @missing + ' Nothing was changed.';
    RAISERROR('537_audit_configuration_list: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. fn_org_assurance_setup_steps
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

-- =====================================================================
-- 2. sp_org_assurance_setup_status (536 body, steps from the function)
-- =====================================================================
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

    -- Header, so the caller knows which version was measured.
    SELECT @definition_id       AS DefinitionId,
           @version_id          AS VersionId,
           @current_version_id  AS CurrentVersionId,
           @current_status_code AS CurrentStatusCode,
           CAST(CASE WHEN @current_status_code = N'Draft'
                     AND @version_id = @current_version_id
                     THEN 1 ELSE 0 END AS BIT) AS IsEditable;

    -- One row per step, from the shared 537 function (the same
    -- definitions the Audit Configuration list and the review gate use).
    -- "details" is Completed by definition: the audit exists and has a
    -- version, or this procedure would have thrown.
    SELECT f.StepKey, f.StepName, f.ItemCount, f.Status
    FROM grac_practice.fn_org_assurance_setup_steps(@organization_id, @version_id) f
    ORDER BY f.StepOrder;
END
GO

-- =====================================================================
-- 3. sp_org_assurance_configuration_list
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

    -- Draft audits whose definition is done up to Question Sets: the
    -- current version has a scope and at least one question set. Their
    -- configuration steps come from the same function as the chips.
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
      AND s.status_code = N'Draft'
      AND st.scope_status     = N'Completed'
      AND st.questions_status = N'Completed'
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
           workflow_status          AS WorkflowStatus,
           scoring_status           AS ScoringStatus,
           trigger_status           AS TriggerStatus,
           resolution_status        AS ScopeResolutionStatus,
           CAST(configured_steps AS INT) AS ConfiguredSteps,
           CAST(4 AS INT)           AS ConfigurationSteps,
           CAST(CASE WHEN configured_steps = 4 THEN 1 ELSE 0 END AS BIT) AS IsConfigured
    FROM #cfg
    ORDER BY definition_name, definition_id
    OFFSET @offset ROWS FETCH NEXT @page_size ROWS ONLY;
END
GO

-- =====================================================================
-- 4. sp_org_assurance_definition_submit (070 body + configuration gate)
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_definition_submit
    @organization_id BIGINT,
    @definition_id   BIGINT,
    @reason_text     NVARCHAR(1000) = NULL,
    @actor           NVARCHAR(100)  = 'system'
AS
BEGIN
    SET NOCOUNT ON;

    -- 537: an audit goes for review only once it is configured -- Scope
    -- and Question Sets (Audit Definition) and Workflow, Scoring, Trigger
    -- and Scope Resolution (Audit Configuration), all Completed for the
    -- current version. Ownership, status and the rest stay with the
    -- transition procedure (a missing / foreign audit skips this check
    -- and fails there with its own error).
    DECLARE @version_id BIGINT, @missing NVARCHAR(400);
    SELECT @version_id = d.current_version_id
      FROM grac_practice.org_assurance_definition d
     WHERE d.org_assurance_definition_id = @definition_id
       AND d.organization_id = @organization_id
       AND d.is_active = 1;

    IF @version_id IS NOT NULL
    BEGIN
        SELECT @missing = STRING_AGG(f.StepName, N', ') WITHIN GROUP (ORDER BY f.StepOrder)
          FROM grac_practice.fn_org_assurance_setup_steps(@organization_id, @version_id) f
         WHERE f.StepKey <> N'details'
           AND f.Status  <> N'Completed';

        IF @missing IS NOT NULL
        BEGIN
            DECLARE @msg NVARCHAR(2048) =
                N'Complete the audit configuration before submitting it for review. Not complete: '
                + @missing + N'.';
            THROW 53612, @msg, 1;
        END
    END

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

-- =====================================================================
-- Verification
-- =====================================================================
SELECT '537 fn_org_assurance_setup_steps exists' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.fn_org_assurance_setup_steps','IF') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END AS Result_
UNION ALL SELECT '537 setup status reads the function',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_org_assurance_setup_status')) LIKE '%fn_org_assurance_setup_steps%' THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT '537 sp_org_assurance_configuration_list exists',
       CASE WHEN OBJECT_ID('grac_practice.sp_org_assurance_configuration_list','P') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
UNION ALL SELECT '537 submit checks the configuration',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_org_assurance_definition_submit')) LIKE '%THROW 53612%' THEN 'PASS' ELSE 'FAIL' END;
PRINT '537 complete. Restart the Api and deploy Web.';
GO
SET NOEXEC OFF;
GO
