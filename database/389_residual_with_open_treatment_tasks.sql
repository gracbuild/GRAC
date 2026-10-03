-- =====================================================================
-- 389_residual_with_open_treatment_tasks.sql
--
-- CHANGE REQUEST 2026-09-27: "While treatment tasks are open a risk
-- should not go to residual risk -- but some organisations have a
-- practical difficulty with that. Give the organisation an option to
-- decide whether the next stage is allowed with open tasks, and make the
-- Residual item on the 3-dot menu active / inactive accordingly."
--
-- WHAT THIS ADDS
--   1. org_risk_config.allow_residual_with_open_tasks  BIT NOT NULL
--      DEFAULT 0. Default keeps today's rule (open tasks block residual).
--      Set from the existing Risk Centre settings dialog.
--   2. sp_risk_config_get / sp_risk_config_save re-issued (212 bodies)
--      with the new column / @allow_residual_with_open_tasks parameter.
--   3. fn_risk_treatment_roots(@risk_register_id) -- the ONE definition of
--      "this risk's treatment work" (the risk's own treatment tasks, tasks
--      from gaps of its mapped practice instances, open tasks mapped with
--      Map open task), previously inline in sp_risk_treatment_state.
--   4. sp_risk_treatment_state re-issued (388 body): roots from the
--      function; ResidualAvailable honours the switch; new column
--      AllowResidualWithOpenTasks.
--   5. sp_risk_residual_analysis_save re-issued (263 body, verbatim
--      except gate 3): gate 3 is skipped when the switch is on, and its
--      open-task count now uses fn_risk_treatment_roots, so the save
--      refuses exactly what the Treatment page says is blocking.
--
-- Idempotent / SAFE TO RE-RUN. ASCII-only.
-- Requires 212, 263, 387, 388.
-- Rollback: 389_residual_with_open_treatment_tasks_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

DECLARE @ok BIT = 1;
IF OBJECT_ID('grac_practice.org_risk_config','U') IS NULL
BEGIN PRINT 'ABORT (389): org_risk_config missing (run 212).'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.risk_treatment_task_link','U') IS NULL
BEGIN PRINT 'ABORT (389): risk_treatment_task_link missing (run 387).'; SET @ok = 0; END
IF COL_LENGTH('grac_practice.custom_gap_practice_map','practice_instance_id') IS NULL
BEGIN PRINT 'ABORT (389): custom_gap_practice_map.practice_instance_id missing (run 388).'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.sp_risk_residual_analysis_save','P') IS NULL
BEGIN PRINT 'ABORT (389): sp_risk_residual_analysis_save missing (run 263).'; SET @ok = 0; END
IF @ok = 0
BEGIN
    RAISERROR('389_residual_with_open_treatment_tasks: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. The switch
-- =====================================================================
IF COL_LENGTH('grac_practice.org_risk_config','allow_residual_with_open_tasks') IS NULL
    ALTER TABLE grac_practice.org_risk_config
        ADD allow_residual_with_open_tasks BIT NOT NULL
            CONSTRAINT df_pm_org_risk_allow_open_residual DEFAULT 0;
GO
PRINT '389: org_risk_config.allow_residual_with_open_tasks ready.';
GO

-- =====================================================================
-- 2. sp_risk_config_get / sp_risk_config_save (212 bodies + the switch)
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_config_get
    @organization_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL
        THROW 56220, 'sp_risk_config_get: organization_id is required.', 1;

    IF NOT EXISTS (SELECT 1 FROM grac_practice.org_risk_config
                    WHERE organization_id = @organization_id)
    BEGIN
        DECLARE @rs INT =
            (SELECT record_status_id FROM grac_practice.record_status_master WHERE status_code = N'Active');
        INSERT INTO grac_practice.org_risk_config
            (organization_id, record_status_id, entered_by)
        VALUES (@organization_id, @rs, N'auto-212');
    END

    SELECT
        c.org_risk_config_id           AS OrgRiskConfigId,
        c.organization_id              AS OrganizationId,
        c.approval_required            AS ApprovalRequired,
        c.approval_min_rating_code     AS ApprovalMinRatingCode,
        c.approver_role_id             AS ApproverRoleId,
        c.approver_role_name           AS ApproverRoleName,
        c.default_raise_treatment_task AS DefaultRaiseTreatmentTask,
        c.allow_legacy_accept          AS AllowLegacyAccept,
        c.notifications_enabled        AS NotificationsEnabled,
        c.notes                        AS Notes,
        -- 389
        c.allow_residual_with_open_tasks AS AllowResidualWithOpenTasks
      FROM grac_practice.org_risk_config c
     WHERE c.organization_id = @organization_id;

    -- Second result set: the notify-role matrix.
    SELECT
        n.notify_event_code AS NotifyEventCode,
        n.role_id           AS RoleId,
        n.role_name         AS RoleName,
        n.is_active         AS IsActive
      FROM grac_practice.org_risk_config_notify_role n
     WHERE n.organization_id = @organization_id
       AND n.is_active = 1
     ORDER BY n.notify_event_code, n.role_name;
END;
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_risk_config_save
    @organization_id              BIGINT,
    @approval_required            BIT           = NULL,
    @approval_min_rating_code     NVARCHAR(30)  = NULL,
    @approver_role_id             BIGINT        = NULL,
    @default_raise_treatment_task BIT           = NULL,
    @allow_legacy_accept          BIT           = NULL,
    @notifications_enabled        BIT           = NULL,
    @notes                        NVARCHAR(1000) = NULL,
    @clear_approver_role          BIT           = 0,
    @clear_min_rating             BIT           = 0,
    @caller_display_name          NVARCHAR(100) = N'system',
    -- 389. NULL = leave alone, like every switch above.
    @allow_residual_with_open_tasks BIT         = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL
        THROW 56221, 'sp_risk_config_save: organization_id is required.', 1;

    IF @approval_min_rating_code IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM grac_practice.risk_matrix_cell
                        WHERE organization_id = @organization_id
                          AND rating_code     = @approval_min_rating_code)
        THROW 56222, 'sp_risk_config_save: approval_min_rating_code is not a rating this organisation''s risk matrix produces.', 1;

    IF @approver_role_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_role
                        WHERE role_id = @approver_role_id)
        THROW 56223, 'sp_risk_config_save: approver_role_id not found.', 1;

    IF NOT EXISTS (SELECT 1 FROM grac_practice.org_risk_config
                    WHERE organization_id = @organization_id)
    BEGIN
        DECLARE @rs INT =
            (SELECT record_status_id FROM grac_practice.record_status_master WHERE status_code = N'Active');
        INSERT INTO grac_practice.org_risk_config
            (organization_id, record_status_id, entered_by)
        VALUES (@organization_id, @rs, @caller_display_name);
    END

    DECLARE @role_name NVARCHAR(200) =
        (SELECT role_name FROM grac_practice.organization_role WHERE role_id = @approver_role_id);

    UPDATE grac_practice.org_risk_config
       SET approval_required            = COALESCE(@approval_required, approval_required),
           approval_min_rating_code     = CASE WHEN @clear_min_rating = 1 THEN NULL
                                               ELSE COALESCE(@approval_min_rating_code, approval_min_rating_code) END,
           approver_role_id             = CASE WHEN @clear_approver_role = 1 THEN NULL
                                               ELSE COALESCE(@approver_role_id, approver_role_id) END,
           approver_role_name           = CASE WHEN @clear_approver_role = 1 THEN NULL
                                               ELSE COALESCE(@role_name, approver_role_name) END,
           default_raise_treatment_task = COALESCE(@default_raise_treatment_task, default_raise_treatment_task),
           allow_legacy_accept          = COALESCE(@allow_legacy_accept, allow_legacy_accept),
           notifications_enabled        = COALESCE(@notifications_enabled, notifications_enabled),
           allow_residual_with_open_tasks = COALESCE(@allow_residual_with_open_tasks, allow_residual_with_open_tasks),
           notes                        = COALESCE(@notes, notes),
           updated_by                   = @caller_display_name,
           updated_dt                   = SYSUTCDATETIME()
     WHERE organization_id = @organization_id;

    EXEC grac_practice.sp_risk_config_get @organization_id = @organization_id;
END;
GO
PRINT '389: sp_risk_config_get / _save carry allow_residual_with_open_tasks.';
GO

-- =====================================================================
-- 3. fn_risk_treatment_roots
--    Priority when a task is reachable more than one way:
--    Treatment > Gap > Linked (the same order 387 used).
-- =====================================================================
CREATE OR ALTER FUNCTION grac_practice.fn_risk_treatment_roots(@risk_register_id BIGINT)
RETURNS TABLE
AS
RETURN
WITH src AS (
    SELECT v.task_id, CAST(N'Treatment' AS NVARCHAR(20)) AS link_source_code, 1 AS prio
      FROM grac_practice.risk_register r
      JOIN grac_practice.vw_pm_practice_task v
        ON v.organization_id = r.organization_id
       AND v.parent_task_id IS NULL
       AND ((v.source_type_code = N'RiskRegister' AND v.source_record_id = r.risk_register_id)
         OR (r.risk_candidate_id IS NOT NULL
             AND v.source_type_code = N'Risk' AND v.source_record_id = r.risk_candidate_id))
     WHERE r.risk_register_id = @risk_register_id

    UNION ALL

    -- Gaps of a mapped practice INSTANCE: gaps whose source is the
    -- instance, and Custom Gaps mapped to it (388).
    SELECT v.task_id, CAST(N'Gap' AS NVARCHAR(20)), 2
      FROM grac_practice.risk_register r
      JOIN grac_practice.risk_practice_map pm
        ON pm.risk_register_id = r.risk_register_id
       AND pm.practice_instance_id IS NOT NULL
      JOIN grac_practice.custom_gap g
        ON (g.source_reference_type = N'PracticeInstance'
            AND g.source_reference_id = pm.practice_instance_id)
        OR EXISTS (SELECT 1
                     FROM grac_practice.custom_gap_practice_map gm
                     JOIN grac_practice.record_status_master rs
                       ON rs.record_status_id = gm.record_status_id
                      AND rs.status_code = N'Active'
                    WHERE gm.custom_gap_id        = g.custom_gap_id
                      AND gm.practice_instance_id = pm.practice_instance_id)
      JOIN grac_practice.vw_pm_practice_task v
        ON v.source_type_code = N'Gap'
       AND v.source_record_id = g.custom_gap_id
       AND v.organization_id  = r.organization_id
       AND v.parent_task_id IS NULL
     WHERE r.risk_register_id = @risk_register_id

    UNION ALL

    -- Open tasks mapped with "Map open task" (387).
    SELECT l.task_id, CAST(N'Linked' AS NVARCHAR(20)), 3
      FROM grac_practice.risk_treatment_task_link l
     WHERE l.risk_register_id = @risk_register_id
)
SELECT x.task_id, x.link_source_code
  FROM (SELECT task_id, link_source_code,
               ROW_NUMBER() OVER (PARTITION BY task_id ORDER BY prio) AS rn
          FROM src) x
 WHERE x.rn = 1;
GO
PRINT '389: fn_risk_treatment_roots created.';
GO

-- =====================================================================
-- 4. sp_risk_treatment_state (388 body; roots from the function; switch)
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_treatment_state
    @risk_register_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    IF @risk_register_id IS NULL
        THROW 56570, 'sp_risk_treatment_state: risk_register_id is required.', 1;

    DECLARE @org_id BIGINT, @candidate_id BIGINT, @option_code NVARCHAR(30),
            @status NVARCHAR(30), @residual_pending BIT, @analysis_pending BIT;

    SELECT @org_id           = organization_id,
           @candidate_id     = risk_candidate_id,
           @option_code      = treatment_option_code,
           @status           = status_code,
           @residual_pending = residual_pending,
           @analysis_pending = analysis_pending
      FROM grac_practice.risk_register
     WHERE risk_register_id = @risk_register_id;

    IF @org_id IS NULL
        THROW 56571, 'sp_risk_treatment_state: risk not found.', 1;

    -- 387/389: the top-level tasks that make up this risk's treatment
    -- work, each with where it came from -- one shared definition,
    -- fn_risk_treatment_roots, also used by the residual save gate.
    CREATE TABLE #roots(TaskId BIGINT PRIMARY KEY, LinkSourceCode NVARCHAR(20));
    INSERT #roots(TaskId, LinkSourceCode)
    SELECT task_id, link_source_code
      FROM grac_practice.fn_risk_treatment_roots(@risk_register_id);

    CREATE TABLE #tt(
        TaskId BIGINT, TaskNumber NVARCHAR(60), Title NVARCHAR(250),
        StatusCode NVARCHAR(30), StatusName NVARCHAR(120), IsTerminal BIT,
        OwnerEmployeeId BIGINT, OwnerName NVARCHAR(240), Priority NVARCHAR(30),
        DueAt DATETIME2, ClosedAt DATETIME2, IsChild BIT, ParentTaskId BIGINT,
        ChildCount INT, MandatoryChildOpenCount INT, RaisedDt DATETIME2,
        LinkSourceCode NVARCHAR(20)
    );

    -- Each root task plus its sub tasks (children inherit the root's
    -- LinkSourceCode). Same columns and order as 263.
    INSERT INTO #tt
    SELECT v.task_id, v.task_number, v.subject_title,
           v.current_status_code, v.current_status_name, v.current_status_is_terminal,
           v.assigned_to_employee_id, v.assigned_to_employee_name, v.priority,
           v.sla_due_at, v.closed_at,
           CASE WHEN v.parent_task_id IS NOT NULL THEN 1 ELSE 0 END,
           v.parent_task_id, v.child_count, v.mandatory_child_open_count, v.entered_dt,
           r.LinkSourceCode
      FROM grac_practice.vw_pm_practice_task v
      JOIN #roots r ON r.TaskId = COALESCE(v.parent_task_id, v.task_id)
     WHERE v.organization_id = @org_id;

    DECLARE @total INT, @open INT, @closed INT, @open_children INT;

    SELECT @total  = COUNT(*),
           @open   = SUM(CASE WHEN ClosedAt IS NULL AND IsTerminal = 0 THEN 1 ELSE 0 END),
           @closed = SUM(CASE WHEN ClosedAt IS NOT NULL OR IsTerminal = 1 THEN 1 ELSE 0 END)
      FROM #tt WHERE IsChild = 0;

    SELECT @open_children = COUNT(*)
      FROM #tt WHERE IsChild = 1 AND ClosedAt IS NULL AND IsTerminal = 0;

    SET @total  = ISNULL(@total, 0);
    SET @open   = ISNULL(@open, 0);
    SET @closed = ISNULL(@closed, 0);

    -- 389: organisation switch -- residual analysis while treatment
    -- work is still open.
    DECLARE @allow_open_residual BIT =
        ISNULL((SELECT c.allow_residual_with_open_tasks
                  FROM grac_practice.org_risk_config c
                 WHERE c.organization_id = @org_id), 0);

    DECLARE @residual_available BIT =
        CASE WHEN ISNULL(@analysis_pending, 1) = 1 THEN 0
             WHEN @status IN (N'Closed', N'Retired')  THEN 0
             WHEN @option_code IS NULL                THEN 0
             WHEN @option_code = N'Tolerate'          THEN 0
             WHEN @total = 0                          THEN 0
             WHEN @open > 0 AND @allow_open_residual = 0 THEN 0
             ELSE 1 END;

    DECLARE @reason NVARCHAR(400) =
        CASE WHEN ISNULL(@analysis_pending, 1) = 1
                  THEN N'Complete the risk analysis first.'
             WHEN @status IN (N'Closed', N'Retired')
                  THEN N'This risk is closed or retired.'
             WHEN @option_code IS NULL
                  THEN N'Choose a treatment option first.'
             WHEN @option_code = N'Tolerate'
                  THEN N'Tolerate / Accept does not require residual analysis -- go to Risk Acceptance.'
             WHEN @total = 0
                  THEN N'No treatment task has been raised yet.'
             WHEN @open > 0 AND @allow_open_residual = 1
                  THEN CONCAT(CAST(@open AS NVARCHAR(10)),
                              N' treatment task(s) still open -- this organisation allows residual risk analysis before treatment work is complete.')
             WHEN @open > 0
                  THEN CONCAT(CAST(@open AS NVARCHAR(10)),
                              N' treatment task(s) still open.',
                              CASE WHEN @open_children > 0
                                   THEN CONCAT(N' ', CAST(@open_children AS NVARCHAR(10)),
                                               N' sub task(s) open.')
                                   ELSE N'' END)
             ELSE N'All treatment tasks are closed -- residual risk analysis is available.'
        END;

    SELECT @risk_register_id   AS RiskRegisterId,
           @option_code        AS TreatmentOptionCode,
           @status             AS StatusCode,
           @total              AS TreatmentTaskCount,
           @open               AS OpenTreatmentTaskCount,
           @closed             AS ClosedTreatmentTaskCount,
           @open_children      AS OpenSubTaskCount,
           @residual_available AS ResidualAvailable,
           ISNULL(@residual_pending, 1) AS ResidualPending,
           @reason             AS Reason,
           @allow_open_residual AS AllowResidualWithOpenTasks;

    SELECT * FROM #tt ORDER BY IsChild, ParentTaskId, TaskId;
    DROP TABLE #tt;
    DROP TABLE #roots;
END;
GO
PRINT '389: sp_risk_treatment_state re-issued.';
GO

-- =====================================================================
-- 5. sp_risk_residual_analysis_save (263 body; gate 3 honours the switch)
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_risk_residual_analysis_save
    @risk_register_id        BIGINT,
    @residual_likelihood_code NVARCHAR(60),
    @residual_impact_code    NVARCHAR(60),
    @treatment_summary       NVARCHAR(MAX) = NULL,
    @residual_controls       NVARCHAR(MAX) = NULL,
    @analyst_remarks         NVARCHAR(MAX) = NULL,
    @assessed_by_employee_id BIGINT        = NULL,
    @caller_display_name     NVARCHAR(100) = N'system',
    -- New in 263. Defaulted, so every 258 caller still compiles.
    @treatment_option_code   NVARCHAR(30)  = NULL,
    @skip_treatment_gate     BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;

    IF @risk_register_id IS NULL
        THROW 56450, 'sp_risk_residual_analysis_save: risk_register_id is required.', 1;
    IF @residual_likelihood_code IS NULL OR LEN(LTRIM(RTRIM(@residual_likelihood_code))) = 0
        THROW 56451, 'sp_risk_residual_analysis_save: residual likelihood is required.', 1;
    IF @residual_impact_code IS NULL OR LEN(LTRIM(RTRIM(@residual_impact_code))) = 0
        THROW 56452, 'sp_risk_residual_analysis_save: residual impact is required.', 1;

    IF @treatment_option_code IS NOT NULL
       AND @treatment_option_code NOT IN (N'Terminate', N'Treat', N'Transfer', N'Tolerate')
        THROW 56573, 'sp_risk_residual_analysis_save: treatment option must be Terminate, Treat, Transfer or Tolerate.', 1;

    DECLARE @org_id BIGINT, @status NVARCHAR(30), @analysis_pending BIT,
            @inherent_analysis_id BIGINT, @candidate_id BIGINT,
            @register_option NVARCHAR(30),
            @inh_code NVARCHAR(30), @inh_name NVARCHAR(120), @inh_score INT;

    SELECT @org_id               = organization_id,
           @status               = status_code,
           @analysis_pending     = analysis_pending,
           @inherent_analysis_id = risk_analysis_id,
           @candidate_id         = risk_candidate_id,
           @register_option      = treatment_option_code,
           @inh_code             = inherent_rating_code,
           @inh_name             = inherent_rating_name,
           @inh_score            = inherent_rating_score
      FROM grac_practice.risk_register
     WHERE risk_register_id = @risk_register_id;

    IF @org_id IS NULL
        THROW 56453, 'sp_risk_residual_analysis_save: risk not found.', 1;

    -- ---- Gate 1 (258): there must be something to be residual TO -----
    IF ISNULL(@analysis_pending, 1) = 1 OR @inh_code IS NULL
        THROW 56454, 'sp_risk_residual_analysis_save: this risk has no inherent rating yet. Complete the risk analysis before assessing residual risk.', 1;

    -- ---- Gate 2 (258): treatment must have been decided (BRD s.17) --------
    IF @status IN (N'Closed', N'Retired')
        THROW 56455, 'sp_risk_residual_analysis_save: this risk is closed or retired -- reopen it before assessing residual risk.', 1;

    IF @status = N'Active'
        THROW 56456, 'sp_risk_residual_analysis_save: residual risk is what remains after treatment. Move this risk to Under treatment, Monitoring or Accepted first.', 1;

    IF @status NOT IN (N'UnderTreatment', N'Monitoring', N'Accepted')
        THROW 56457, 'sp_risk_residual_analysis_save: residual risk can only be assessed on a risk under treatment, monitoring or accepted.', 1;

    -- ---- Gate 3 (263, NEW): the treatment must actually be FINISHED --
    -- Only meaningful where treatment work was raised. A Tolerate risk,
    -- and a risk from before this migration with no option recorded, are
    -- both governed by gate 2 alone -- tightening the rule must not make
    -- existing data unassessable (validation case 13).
    --
    -- @skip_treatment_gate exists for one caller: the review flow (264),
    -- which re-opens a risk and re-scores it before the NEXT round of
    -- treatment. It is not a general escape hatch and no screen sends it.
    --
    -- 389: skipped when the organisation allows residual analysis while
    -- treatment work is still open (org_risk_config.
    -- allow_residual_with_open_tasks). The count now covers every task
    -- the Treatment page lists (fn_risk_treatment_roots: the risk's own
    -- treatment tasks, tasks from gaps of its mapped practice instances,
    -- and open tasks mapped to it) plus their sub tasks.
    DECLARE @allow_open_residual BIT =
        ISNULL((SELECT c.allow_residual_with_open_tasks
                  FROM grac_practice.org_risk_config c
                 WHERE c.organization_id = @org_id), 0);

    IF ISNULL(@skip_treatment_gate, 0) = 0
       AND @allow_open_residual = 0
       AND @register_option IN (N'Terminate', N'Treat', N'Transfer')
    BEGIN
        DECLARE @open_tasks INT;

        SELECT @open_tasks = COUNT(*)
          FROM grac_practice.vw_pm_practice_task v
          JOIN grac_practice.fn_risk_treatment_roots(@risk_register_id) rt
            ON rt.task_id = COALESCE(v.parent_task_id, v.task_id)
         WHERE v.organization_id = @org_id
           AND v.closed_at IS NULL
           AND v.current_status_is_terminal = 0;

        IF ISNULL(@open_tasks, 0) > 0
        BEGIN
            DECLARE @gate_msg NVARCHAR(400) = CONCAT(
                N'sp_risk_residual_analysis_save: ', CAST(@open_tasks AS NVARCHAR(10)),
                N' treatment task(s) are still open. Residual risk can only be assessed once all treatment work is complete.');
            THROW 56574, @gate_msg, 1;
        END
    END

    -- ---- Resolve the scale -- the SAME masters as the inherent path --
    DECLARE @lk_name NVARCHAR(200), @lk_value INT,
            @im_name NVARCHAR(200), @im_value INT;

    SELECT @lk_name = likelihood_name, @lk_value = level_value
      FROM grac_practice.risk_likelihood_master
     WHERE organization_id = @org_id
       AND likelihood_code = @residual_likelihood_code
       AND status = N'Active';
    IF @lk_value IS NULL
        THROW 56458, 'sp_risk_residual_analysis_save: unknown residual likelihood_code for this organisation.', 1;

    SELECT @im_name = impact_name, @im_value = level_value
      FROM grac_practice.risk_impact_master
     WHERE organization_id = @org_id
       AND impact_code = @residual_impact_code
       AND status = N'Active';
    IF @im_value IS NULL
        THROW 56459, 'sp_risk_residual_analysis_save: unknown residual impact_code for this organisation.', 1;

    DECLARE @rt_code NVARCHAR(30), @rt_name NVARCHAR(120), @rt_score INT;
    EXEC grac_practice.sp_risk_rating_resolve
         @organization_id  = @org_id,
         @likelihood_value = @lk_value,
         @impact_value     = @im_value,
         @rating_code      = @rt_code  OUTPUT,
         @rating_name      = @rt_name  OUTPUT,
         @rating_score     = @rt_score OUTPUT;

    IF @rt_code IS NULL
        THROW 56460, 'sp_risk_residual_analysis_save: the residual likelihood/impact pair resolved to no rating. Check the organisation''s risk matrix configuration.', 1;

    DECLARE @option_name NVARCHAR(120) =
        CASE @treatment_option_code
             WHEN N'Terminate' THEN N'Terminate / Avoid'
             WHEN N'Treat'     THEN N'Treat / Reduce'
             WHEN N'Transfer'  THEN N'Transfer / Share'
             WHEN N'Tolerate'  THEN N'Tolerate / Accept'
             ELSE NULL
        END;

    DECLARE @active_rs INT =
        (SELECT record_status_id FROM grac_practice.record_status_master WHERE status_code = N'Active');

    DECLARE @next_version INT = 1, @residual_id BIGINT;

    BEGIN TRY
        BEGIN TRAN;

        SELECT @next_version = ISNULL(MAX(residual_version), 0) + 1
          FROM grac_practice.risk_residual_analysis
         WHERE risk_register_id = @risk_register_id;

        UPDATE grac_practice.risk_residual_analysis
           SET is_current = 0,
               updated_by = @caller_display_name,
               updated_dt = SYSUTCDATETIME()
         WHERE risk_register_id = @risk_register_id
           AND is_current = 1;

        INSERT INTO grac_practice.risk_residual_analysis
            (organization_id, risk_register_id, inherent_analysis_id,
             residual_version, is_current,
             residual_likelihood_code, residual_likelihood_name, residual_likelihood_value,
             residual_impact_code, residual_impact_name, residual_impact_value,
             residual_rating_code, residual_rating_name, residual_rating_score,
             inherent_rating_code, inherent_rating_name, inherent_rating_score,
             treatment_summary, residual_controls, analyst_remarks,
             treatment_option_code, treatment_option_name,
             assessed_dt, assessed_by_employee_id,
             record_status_id, entered_by, entered_dt)
        VALUES
            (@org_id, @risk_register_id, @inherent_analysis_id,
             @next_version, 1,
             @residual_likelihood_code, @lk_name, @lk_value,
             @residual_impact_code, @im_name, @im_value,
             @rt_code, @rt_name, @rt_score,
             @inh_code, @inh_name, @inh_score,
             @treatment_summary, @residual_controls, @analyst_remarks,
             @treatment_option_code, @option_name,
             SYSUTCDATETIME(), @assessed_by_employee_id,
             @active_rs, @caller_display_name, SYSUTCDATETIME());

        SET @residual_id = SCOPE_IDENTITY();

        UPDATE grac_practice.risk_register
           SET residual_analysis_id      = @residual_id,
               residual_likelihood_code  = @residual_likelihood_code,
               residual_likelihood_name  = @lk_name,
               residual_likelihood_value = @lk_value,
               residual_impact_code      = @residual_impact_code,
               residual_impact_name      = @im_name,
               residual_impact_value     = @im_value,
               residual_rating_code      = @rt_code,
               residual_rating_name      = @rt_name,
               residual_rating_score     = @rt_score,
               residual_assessed_dt      = SYSUTCDATETIME(),
               residual_pending          = 0,
               updated_by                = @caller_display_name,
               updated_dt                = SYSUTCDATETIME()
         WHERE risk_register_id = @risk_register_id;

        INSERT INTO grac_practice.risk_register_history
            (risk_register_id, action_code, from_status_code, to_status_code,
             remark, actor_employee_id, actor_display_name, entered_by, entered_dt)
        VALUES
            (@risk_register_id, N'ResidualAssessed', @status, @status,
             CONCAT(N'Residual assessment v', CAST(@next_version AS NVARCHAR(10)),
                    N'. Inherent ', ISNULL(@inh_code, N'(none)'),
                    N' -> residual ', @rt_code,
                    N' (', @lk_name, N' x ', @im_name, N').',
                    CASE WHEN @option_name IS NULL THEN N''
                         ELSE CONCAT(N' Concluded: ', @option_name, N'.') END),
             @assessed_by_employee_id, @caller_display_name,
             @caller_display_name, SYSUTCDATETIME());

        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH

    -- The residual assessment can itself conclude with a NEW treatment
    -- decision -- a risk still too high after one round gets another.
    -- Delegated to the one writer of that decision, outside the
    -- transaction, for the reason section 2 gives.
    --
    -- @suppress_result = 1 is NOT optional here. Without it the inner
    -- SELECT becomes this procedure's FIRST result set and the caller,
    -- reading result set 1 for the residual score, gets the treatment
    -- dispatch instead.
    IF @treatment_option_code IS NOT NULL
        EXEC grac_practice.sp_risk_treatment_option_set
             @risk_register_id      = @risk_register_id,
             @treatment_option_code = @treatment_option_code,
             @remark                = N'Set from residual risk analysis.',
             @actor_employee_id     = @assessed_by_employee_id,
             @caller_display_name   = @caller_display_name,
             @suppress_result       = 1;

    SELECT @risk_register_id AS RiskRegisterId,
           @residual_id      AS RiskResidualAnalysisId,
           @next_version     AS ResidualVersion,
           @rt_code          AS ResidualRatingCode,
           @rt_name          AS ResidualRatingName,
           @rt_score         AS ResidualRatingScore,
           @inh_code         AS InherentRatingCode,
           @inh_score        AS InherentRatingScore,
           -- New in 263, appended so 258's column order is preserved.
           @treatment_option_code AS TreatmentOptionCode,
           @option_name           AS TreatmentOptionName;
END;
GO
PRINT '389: sp_risk_residual_analysis_save re-issued.';
GO

-- =====================================================================
-- Verification
-- =====================================================================
SELECT '389-a switch column' AS [check],
       CASE WHEN COL_LENGTH('grac_practice.org_risk_config','allow_residual_with_open_tasks') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS result
UNION ALL
SELECT '389-b residual save honours the switch',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_risk_residual_analysis_save'))
                 LIKE '%allow_residual_with_open_tasks%' THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '389-c residual_version still assigned by its own proc (310-i)',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_risk_residual_analysis_save'))
                 LIKE '%MAX(residual_version)%' THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '389-d treatment state uses fn_risk_treatment_roots',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_risk_treatment_state'))
                 LIKE '%fn_risk_treatment_roots%' THEN 'PASS' ELSE 'FAIL' END;

SELECT '389-e organisations allowing residual with open tasks' AS [check],
       COUNT(*) AS orgs
  FROM grac_practice.org_risk_config
 WHERE allow_residual_with_open_tasks = 1;
GO
SET NOEXEC OFF;
GO
