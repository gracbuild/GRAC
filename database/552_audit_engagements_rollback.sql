-- =====================================================================
-- 552 ROLLBACK -- restores the 551 bodies of sp_org_assurance_plan_item_save
-- / _list / _start_execution and drops the 552 procedures. The
-- org_assurance_engagement_definition table and the engagement_code /
-- engagement_name columns are KEPT (an engagement's second and later
-- audits stay recorded there, unread). Deploy the pre-552 Api and Web
-- with it. Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_plan_item_save
    @organization_id             BIGINT,
    @plan_id                     BIGINT,
    @plan_item_id                BIGINT        = NULL,
    @org_assurance_definition_id BIGINT,
    @definition_code             NVARCHAR(80)  = NULL,
    @definition_name             NVARCHAR(240) = NULL,
    @item_order                  INT           = 0,
    @scheduled_from              DATE          = NULL,
    @scheduled_to                DATE          = NULL,
    @assigned_auditor_role_id    BIGINT        = NULL,   -- 121
    @assigned_auditor_role_name  NVARCHAR(120) = NULL,   -- 121
    @assigned_auditor_employee_id BIGINT       = NULL,
    @assigned_auditor_name       NVARCHAR(240) = NULL,
    @assigned_team_name          NVARCHAR(200) = NULL,
    @assigned_department_id      BIGINT        = NULL,
    @assigned_department_name    NVARCHAR(200) = NULL,
    @assigned_branch_id          BIGINT        = NULL,
    @assigned_branch_name        NVARCHAR(200) = NULL,
    @notes                       NVARCHAR(MAX) = NULL,
    @actor                       NVARCHAR(100) = 'system',
    @plan_item_id_out            BIGINT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @organization_id IS NULL OR @plan_id IS NULL
        THROW 53902, 'organization_id and plan_id are required.', 1;
    IF @org_assurance_definition_id IS NULL
        THROW 53913, 'org_assurance_definition_id is required.', 1;

    -- Verify plan ownership.
    IF NOT EXISTS (
        SELECT 1 FROM grac_practice.org_assurance_plan
        WHERE org_assurance_plan_id = @plan_id
          AND organization_id       = @organization_id
          AND is_active = 1)
        THROW 53908, 'Plan belongs to a different organization.', 1;

    -- Verify definition ownership.
    IF NOT EXISTS (
        SELECT 1 FROM grac_practice.org_assurance_definition
        WHERE org_assurance_definition_id = @org_assurance_definition_id
          AND organization_id            = @organization_id
          AND is_active = 1)
        THROW 53914, 'Assurance definition not accessible in this organization.', 1;

    -- 546: slots change only while the plan can still be edited (Draft /
    -- Submitted -- the plan header's own rule, 121); only an Active audit
    -- is planned; a slot lies inside the plan period, from <= to. The code
    -- and name are the audit's own (the snapshot no longer trusts the
    -- caller's copy).
    DECLARE @plan_status NVARCHAR(60), @period_from DATE, @period_to DATE;
    SELECT @plan_status = s.status_code,
           @period_from = p.period_from,
           @period_to   = p.period_to
      FROM grac_practice.org_assurance_plan p
      JOIN grac_practice.org_assurance_plan_status_master s
           ON s.org_assurance_plan_status_id = p.status_id
     WHERE p.org_assurance_plan_id = @plan_id;
    IF @plan_status NOT IN (N'Draft', N'Submitted')
        THROW 53909, 'Plan items can be changed only while the plan is Draft or Submitted.', 1;

    -- 551: an audit with an Active version that is not Retired can be
    -- planned, also while a revised Draft version is in progress.
    DECLARE @def_status NVARCHAR(60), @def_active_version BIGINT;
    SELECT @def_status         = s.status_code,
           @def_active_version = d.active_version_id,
           @definition_code    = d.definition_code,
           @definition_name    = d.definition_name
      FROM grac_practice.org_assurance_definition d
      JOIN grac_practice.org_assurance_status_master s
           ON s.org_assurance_status_id = d.current_status_id
     WHERE d.org_assurance_definition_id = @org_assurance_definition_id;
    IF @def_active_version IS NULL OR @def_status = N'Retired'
        THROW 53933, 'Only an audit with an Active version can be added to a plan.', 1;

    IF @scheduled_from IS NOT NULL AND @scheduled_to IS NOT NULL AND @scheduled_to < @scheduled_from
        THROW 53934, 'Scheduled To must be on or after Scheduled From.', 1;
    IF (@period_from IS NOT NULL AND (@scheduled_from < @period_from OR @scheduled_to < @period_from))
       OR (@period_to IS NOT NULL AND (@scheduled_from > @period_to OR @scheduled_to > @period_to))
        THROW 53934, 'The scheduled dates must fall within the plan period.', 1;

    -- ==========================================================
    -- 121 hybrid ownership resolver -- Auditor
    -- ==========================================================
    IF @assigned_auditor_role_id IS NOT NULL
       AND (@assigned_auditor_role_name IS NULL OR LEN(LTRIM(RTRIM(@assigned_auditor_role_name))) = 0)
        SELECT @assigned_auditor_role_name = role_name
        FROM grac_practice.organization_role
        WHERE role_id = @assigned_auditor_role_id AND organization_id = @organization_id;

    IF @assigned_auditor_role_id IS NOT NULL AND @assigned_auditor_employee_id IS NULL
        EXEC grac_practice.sp_org_role_primary_holder_pick
             @organization_id   = @organization_id,
             @role_id           = @assigned_auditor_role_id,
             @employee_id_out   = @assigned_auditor_employee_id  OUTPUT,
             @employee_name_out = @assigned_auditor_name         OUTPUT;

    IF @assigned_auditor_employee_id IS NOT NULL AND @assigned_auditor_role_id IS NULL
    BEGIN
        SELECT @assigned_auditor_role_id   = e.role_id,
               @assigned_auditor_role_name = r.role_name
        FROM grac_practice.organization_employee e
        LEFT JOIN grac_practice.organization_role r ON r.role_id = e.role_id
        WHERE e.employee_id = @assigned_auditor_employee_id
          AND e.organization_id = @organization_id;
    END

    IF @assigned_auditor_employee_id IS NOT NULL
       AND (@assigned_auditor_name IS NULL OR LEN(LTRIM(RTRIM(@assigned_auditor_name))) = 0)
        SELECT @assigned_auditor_name = employee_name
        FROM grac_practice.organization_employee
        WHERE employee_id = @assigned_auditor_employee_id;

    BEGIN TRAN;

    IF @plan_item_id IS NULL
    BEGIN
        INSERT INTO grac_practice.org_assurance_plan_item
            (org_assurance_plan_id, organization_id,
             org_assurance_definition_id, definition_code, definition_name,
             item_order, scheduled_from, scheduled_to,
             assigned_auditor_role_id, assigned_auditor_role_name,       -- 121
             assigned_auditor_employee_id, assigned_auditor_name,
             assigned_team_name,
             assigned_department_id, assigned_department_name,
             assigned_branch_id, assigned_branch_name,
             notes, is_active, entered_by, entered_dt)
        VALUES
            (@plan_id, @organization_id,
             @org_assurance_definition_id, @definition_code, @definition_name,
             ISNULL(@item_order, 0), @scheduled_from, @scheduled_to,
             @assigned_auditor_role_id, @assigned_auditor_role_name,     -- 121
             @assigned_auditor_employee_id, @assigned_auditor_name,
             @assigned_team_name,
             @assigned_department_id, @assigned_department_name,
             @assigned_branch_id, @assigned_branch_name,
             @notes, 1, @actor, SYSUTCDATETIME());

        SET @plan_item_id_out = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        DECLARE @item_plan BIGINT;
        SELECT @item_plan = org_assurance_plan_id
        FROM grac_practice.org_assurance_plan_item
        WHERE org_assurance_plan_item_id = @plan_item_id
          AND is_active = 1;

        IF @item_plan IS NULL BEGIN ROLLBACK; THROW 53915, 'Plan item not found.', 1; END
        IF @item_plan <> @plan_id
        BEGIN ROLLBACK; THROW 53916, 'Plan item does not belong to the specified plan.', 1; END

        UPDATE grac_practice.org_assurance_plan_item
        SET org_assurance_definition_id = @org_assurance_definition_id,
            definition_code             = @definition_code,
            definition_name             = @definition_name,
            item_order                  = ISNULL(@item_order, 0),
            scheduled_from              = @scheduled_from,
            scheduled_to                = @scheduled_to,
            assigned_auditor_role_id    = @assigned_auditor_role_id,       -- 121
            assigned_auditor_role_name  = @assigned_auditor_role_name,     -- 121
            assigned_auditor_employee_id = @assigned_auditor_employee_id,
            assigned_auditor_name       = @assigned_auditor_name,
            assigned_team_name          = @assigned_team_name,
            assigned_department_id      = @assigned_department_id,
            assigned_department_name    = @assigned_department_name,
            assigned_branch_id          = @assigned_branch_id,
            assigned_branch_name        = @assigned_branch_name,
            notes                       = @notes,
            updated_by                  = @actor,
            updated_dt                  = SYSUTCDATETIME()
        WHERE org_assurance_plan_item_id = @plan_item_id;

        SET @plan_item_id_out = @plan_item_id;
    END

    COMMIT;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_plan_item_list
    @organization_id BIGINT,
    @plan_id         BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL OR @plan_id IS NULL
        THROW 53902, 'organization_id and plan_id are required.', 1;

    IF NOT EXISTS (
        SELECT 1 FROM grac_practice.org_assurance_plan
        WHERE org_assurance_plan_id = @plan_id
          AND organization_id       = @organization_id)
        THROW 53908, 'Plan belongs to a different organization.', 1;

    SELECT i.org_assurance_plan_item_id  AS PlanItemId,
           i.org_assurance_plan_id       AS PlanId,
           i.org_assurance_definition_id AS DefinitionId,
           i.definition_code             AS DefinitionCode,
           i.definition_name             AS DefinitionName,
           i.org_assurance_definition_version_id AS DefinitionVersionId,
           i.item_order                  AS ItemOrder,
           i.scheduled_from              AS ScheduledFrom,
           i.scheduled_to                AS ScheduledTo,
           i.assigned_auditor_role_id    AS AssignedAuditorRoleId,      -- 121
           i.assigned_auditor_role_name  AS AssignedAuditorRoleName,    -- 121
           i.assigned_auditor_employee_id AS AssignedAuditorEmployeeId,
           i.assigned_auditor_name       AS AssignedAuditorName,
           i.assigned_team_name          AS AssignedTeamName,
           i.assigned_department_id      AS AssignedDepartmentId,
           i.assigned_department_name    AS AssignedDepartmentName,
           i.assigned_branch_id          AS AssignedBranchId,
           i.assigned_branch_name        AS AssignedBranchName,
           i.notes                       AS Notes,
           i.entered_by                  AS EnteredBy,
           i.entered_dt                  AS EnteredDt,
           i.updated_by                  AS UpdatedBy,
           i.updated_dt                  AS UpdatedDt,
           -- 546: the audit's current status, the slot's latest execution,
           -- and the slot status derived from them:
           --   InProgress / Completed  -- a live execution (Completed once
           --                              Approved or Closed);
           --   NotExecuted             -- none, and the audit is Retired or
           --                              the plan Closed;
           --   Planned                 -- none yet (a Cancelled one counts
           --                              as none).
           ds.status_code                AS DefinitionStatusCode,
           ds.status_name                AS DefinitionStatusName,
           -- 551: the audit can be planned / executed -- it has an Active
           -- version and is not Retired (a revision may be in Draft).
           CAST(CASE WHEN d.active_version_id IS NOT NULL AND ds.status_code <> N'Retired'
                     THEN 1 ELSE 0 END AS BIT) AS DefinitionIsPlannable,
           ex.org_assurance_execution_id AS ExecutionId,
           ex.execution_code             AS ExecutionCode,
           ex.status_code                AS ExecutionStatusCode,
           ex.status_name                AS ExecutionStatusName,
           CASE WHEN ex.org_assurance_execution_id IS NOT NULL AND ex.status_code <> N'Cancelled'
                     THEN CASE WHEN ex.status_code IN (N'Approved', N'Closed') THEN N'Completed' ELSE N'InProgress' END
                WHEN ds.status_code = N'Retired' OR ps.status_code = N'Closed'
                     THEN N'NotExecuted'
                ELSE N'Planned' END      AS SlotStatus
    FROM grac_practice.org_assurance_plan_item i
    JOIN grac_practice.org_assurance_plan p
         ON p.org_assurance_plan_id = i.org_assurance_plan_id
    JOIN grac_practice.org_assurance_plan_status_master ps
         ON ps.org_assurance_plan_status_id = p.status_id
    LEFT JOIN grac_practice.org_assurance_definition d
         ON d.org_assurance_definition_id = i.org_assurance_definition_id
    LEFT JOIN grac_practice.org_assurance_status_master ds
         ON ds.org_assurance_status_id = d.current_status_id
    OUTER APPLY (
        SELECT TOP 1 e.org_assurance_execution_id, e.execution_code,
               es.status_code, es.status_name
          FROM grac_practice.org_assurance_execution e
          JOIN grac_practice.org_assurance_execution_status_master es
               ON es.org_assurance_execution_status_id = e.execution_status_id
         WHERE e.org_assurance_plan_item_id = i.org_assurance_plan_item_id
           AND e.organization_id = i.organization_id
           AND e.is_active = 1
         ORDER BY CASE WHEN es.status_code = N'Cancelled' THEN 1 ELSE 0 END,
                  e.org_assurance_execution_id DESC
    ) ex
    WHERE i.org_assurance_plan_id = @plan_id
      AND i.organization_id       = @organization_id
      AND i.is_active = 1
    ORDER BY i.item_order, i.org_assurance_plan_item_id;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_plan_item_start_execution
    @organization_id  BIGINT,
    @plan_id          BIGINT,
    @plan_item_id     BIGINT,
    @actor            NVARCHAR(100) = 'system',
    @execution_id_out BIGINT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @organization_id IS NULL OR @plan_id IS NULL OR @plan_item_id IS NULL
        THROW 53902, 'organization_id, plan_id and plan_item_id are required.', 1;

    DECLARE @item_plan BIGINT, @definition_id BIGINT,
            @from DATE, @to DATE,
            @aud_role_id BIGINT, @aud_role_name NVARCHAR(120),
            @aud_emp_id BIGINT, @aud_name NVARCHAR(240),
            @team NVARCHAR(200);
    SELECT @item_plan     = i.org_assurance_plan_id,
           @definition_id = i.org_assurance_definition_id,
           @from          = i.scheduled_from,
           @to            = i.scheduled_to,
           @aud_role_id   = i.assigned_auditor_role_id,
           @aud_role_name = i.assigned_auditor_role_name,
           @aud_emp_id    = i.assigned_auditor_employee_id,
           @aud_name      = i.assigned_auditor_name,
           @team          = i.assigned_team_name
      FROM grac_practice.org_assurance_plan_item i
     WHERE i.org_assurance_plan_item_id = @plan_item_id
       AND i.organization_id = @organization_id
       AND i.is_active = 1;

    IF @item_plan IS NULL      THROW 53915, 'Plan item not found.', 1;
    IF @item_plan <> @plan_id  THROW 53916, 'Plan item does not belong to the specified plan.', 1;

    IF NOT EXISTS (
        SELECT 1 FROM grac_practice.org_assurance_plan p
          JOIN grac_practice.org_assurance_plan_status_master s
               ON s.org_assurance_plan_status_id = p.status_id
         WHERE p.org_assurance_plan_id = @plan_id
           AND p.organization_id = @organization_id
           AND p.is_active = 1
           AND s.status_code IN (N'Approved', N'Active'))
        THROW 53935, 'An execution can be started only from an Approved or Active plan.', 1;

    -- 551: run the audit's ACTIVE version (its current version may be a
    -- Draft revision); no Active version, or Retired, cannot be executed.
    DECLARE @active_version_id BIGINT;
    SELECT @active_version_id = d.active_version_id
      FROM grac_practice.org_assurance_definition d
      JOIN grac_practice.org_assurance_status_master s
           ON s.org_assurance_status_id = d.current_status_id
     WHERE d.org_assurance_definition_id = @definition_id
       AND s.status_code <> N'Retired';
    IF @active_version_id IS NULL
        THROW 53933, 'The audit has no Active version (it may have been retired), so this slot cannot be executed.', 1;

    IF EXISTS (
        SELECT 1 FROM grac_practice.org_assurance_execution e
          JOIN grac_practice.org_assurance_execution_status_master es
               ON es.org_assurance_execution_status_id = e.execution_status_id
         WHERE e.org_assurance_plan_item_id = @plan_item_id
           AND e.is_active = 1
           AND es.status_code <> N'Cancelled')
        THROW 53936, 'This plan item already has an execution.', 1;

    -- The slot becomes the execution: its dates, its auditor as the
    -- owner, its team. No snapshot is passed, so the scope is resolved
    -- now (545). Materialize runs its own transaction.
    EXEC grac_practice.sp_org_assurance_execution_materialize
         @organization_id     = @organization_id,
         @definition_id       = @definition_id,
         @version_id          = @active_version_id,   -- 551
         @scope_resolution_id = NULL,
         @execution_code      = NULL,
         @execution_name      = NULL,
         @origin_type         = N'PLAN',
         @plan_id             = @plan_id,
         @plan_item_id        = @plan_item_id,
         @trigger_config_id   = NULL,
         @planned_start_dt    = @from,
         @planned_end_dt      = @to,
         @owner_role_id       = @aud_role_id,
         @owner_role_name     = @aud_role_name,
         @owner_employee_id   = @aud_emp_id,
         @owner_display_name  = @aud_name,
         @assigned_team_name  = @team,
         @notes               = NULL,
         @actor               = @actor,
         @execution_id_out    = @execution_id_out OUTPUT;

    SELECT e.org_assurance_execution_id AS ExecutionId,
           e.execution_code             AS ExecutionCode,
           e.execution_name             AS ExecutionName,
           e.total_entity_count         AS TotalEntityCount
      FROM grac_practice.org_assurance_execution e
     WHERE e.org_assurance_execution_id = @execution_id_out;
END
GO

IF OBJECT_ID('grac_practice.sp_org_assurance_engagement_definition_list','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_engagement_definition_list;
GO
IF OBJECT_ID('grac_practice.sp_org_assurance_engagement_scope_preview','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_engagement_scope_preview;
GO
PRINT '552 rolled back (procedures). Table and columns kept.';
GO
