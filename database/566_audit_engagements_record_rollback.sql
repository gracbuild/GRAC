-- 566 rollback  Audit Engagements as a distinct record
-- Restores sp_org_assurance_plan_item_save / _list (565), start_execution /
-- my_audits_prepare / my_audit_list (555), sp_org_responsibility_holder_list
-- (553) and fn_org_assurance_engagement_progress (565); drops the engagement
-- procedures and functions; sets the Audit Engagements menu Inactive.
-- Kept: the new columns, the initiation master, the team table (data), and
-- org_assurance_plan_item.org_assurance_plan_id stays NULLable (independent
-- engagements have no plan; the 565 bodies simply do not list them).
SET NOCOUNT ON;
GO

UPDATE grac_practice.menu_master
   SET status = N'Inactive', updated_by = 'rollback-566', updated_dt = SYSUTCDATETIME()
 WHERE menu_key = N'org-audit-engagements';
GO

IF OBJECT_ID('grac_practice.sp_org_assurance_engagement_delete','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_engagement_delete;
IF OBJECT_ID('grac_practice.sp_org_assurance_engagement_cancel','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_engagement_cancel;
IF OBJECT_ID('grac_practice.sp_org_assurance_engagement_approve','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_engagement_approve;
IF OBJECT_ID('grac_practice.sp_org_assurance_engagement_team_save','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_engagement_team_save;
IF OBJECT_ID('grac_practice.sp_org_assurance_engagement_team_apply','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_engagement_team_apply;
IF OBJECT_ID('grac_practice.sp_org_assurance_engagement_team_list','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_engagement_team_list;
IF OBJECT_ID('grac_practice.sp_org_assurance_engagement_get','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_engagement_get;
IF OBJECT_ID('grac_practice.sp_org_assurance_engagement_list','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_engagement_list;
IF OBJECT_ID('grac_practice.sp_org_assurance_engagement_initiation_list','P') IS NOT NULL DROP PROCEDURE grac_practice.sp_org_assurance_engagement_initiation_list;
GO

-- plan_item_save / plan_item_list: 565 bodies
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_plan_item_save
    @organization_id             BIGINT,
    @plan_id                     BIGINT,
    @plan_item_id                BIGINT        = NULL,
    @org_assurance_definition_id BIGINT        = NULL,   -- 552: or @definitions_json
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
    @engagement_name             NVARCHAR(240) = NULL,   -- 552
    @definitions_json            NVARCHAR(MAX) = NULL,   -- 552: [{"definitionId": 1}, ...] in order
    @programme_id                BIGINT        = NULL,   -- 565: the programme (mandatory)
    @actor                       NVARCHAR(100) = 'system',
    @plan_item_id_out            BIGINT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @organization_id IS NULL OR @plan_id IS NULL
        THROW 53902, 'organization_id and plan_id are required.', 1;

    -- Verify plan ownership.
    IF NOT EXISTS (
        SELECT 1 FROM grac_practice.org_assurance_plan
        WHERE org_assurance_plan_id = @plan_id
          AND organization_id       = @organization_id
          AND is_active = 1)
        THROW 53908, 'Plan belongs to a different organization.', 1;

    -- 552: the engagement's audits, in order -- @definitions_json, or the
    -- single @org_assurance_definition_id of the pre-552 callers.
    DECLARE @defs TABLE (
        definition_id   BIGINT NOT NULL PRIMARY KEY,
        display_order   INT    NOT NULL,
        definition_code NVARCHAR(80)  NULL,
        definition_name NVARCHAR(240) NULL);
    IF @definitions_json IS NOT NULL AND ISJSON(@definitions_json) = 1
    BEGIN
        IF EXISTS (SELECT TRY_CAST(JSON_VALUE(j.[value], '$.definitionId') AS BIGINT)
                     FROM OPENJSON(@definitions_json) j
                    WHERE TRY_CAST(JSON_VALUE(j.[value], '$.definitionId') AS BIGINT) IS NOT NULL
                    GROUP BY TRY_CAST(JSON_VALUE(j.[value], '$.definitionId') AS BIGINT)
                   HAVING COUNT(*) > 1)
            THROW 53937, 'The same audit is listed more than once in the engagement.', 1;
        INSERT INTO @defs (definition_id, display_order)
        SELECT TRY_CAST(JSON_VALUE(j.[value], '$.definitionId') AS BIGINT),
               ROW_NUMBER() OVER (ORDER BY CAST(j.[key] AS INT))
          FROM OPENJSON(@definitions_json) j
         WHERE TRY_CAST(JSON_VALUE(j.[value], '$.definitionId') AS BIGINT) IS NOT NULL;
    END
    ELSE IF @org_assurance_definition_id IS NOT NULL
        INSERT INTO @defs (definition_id, display_order) VALUES (@org_assurance_definition_id, 1);

    IF NOT EXISTS (SELECT 1 FROM @defs)
        THROW 53913, 'Pick at least one audit for the engagement.', 1;

    -- Verify definition ownership.
    IF EXISTS (
        SELECT 1 FROM @defs x
         WHERE NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_definition d
                            WHERE d.org_assurance_definition_id = x.definition_id
                              AND d.organization_id = @organization_id
                              AND d.is_active = 1))
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

    -- 565: every engagement belongs to a programme of its plan. Not given:
    -- the engagement's own (an edit), else the plan's only programme.
    IF @programme_id IS NULL AND @plan_item_id IS NOT NULL
        SELECT @programme_id = org_assurance_programme_id
          FROM grac_practice.org_assurance_plan_item
         WHERE org_assurance_plan_item_id = @plan_item_id;
    IF @programme_id IS NULL
       AND (SELECT COUNT(*) FROM grac_practice.org_assurance_plan_programme
             WHERE org_assurance_plan_id = @plan_id AND is_active = 1) = 1
        SELECT @programme_id = org_assurance_programme_id
          FROM grac_practice.org_assurance_plan_programme
         WHERE org_assurance_plan_id = @plan_id AND is_active = 1;
    IF @programme_id IS NULL
        THROW 53943, 'Pick the programme this engagement belongs to. A plan needs a programme before engagements are added.', 1;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_plan_programme
                    WHERE org_assurance_programme_id = @programme_id
                      AND org_assurance_plan_id = @plan_id AND is_active = 1)
        THROW 53944, 'The programme is not part of this plan.', 1;

    -- 551: an audit with an Active version that is not Retired can be
    -- planned, also while a revised Draft version is in progress.
    -- 552: for every audit of the engagement; one already started on this
    -- engagement may stay whatever its state now.
    UPDATE x
       SET definition_code = d.definition_code,
           definition_name = d.definition_name
      FROM @defs x
      JOIN grac_practice.org_assurance_definition d ON d.org_assurance_definition_id = x.definition_id;

    DECLARE @not_plannable NVARCHAR(MAX), @msg NVARCHAR(2000);
    SELECT @not_plannable = STRING_AGG(CONVERT(NVARCHAR(MAX), x.definition_code), N', ')
      FROM @defs x
      JOIN grac_practice.org_assurance_definition d ON d.org_assurance_definition_id = x.definition_id
      JOIN grac_practice.org_assurance_status_master s ON s.org_assurance_status_id = d.current_status_id
     WHERE (d.active_version_id IS NULL OR s.status_code = N'Retired')
       AND NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_execution e
                         JOIN grac_practice.org_assurance_execution_status_master es
                              ON es.org_assurance_execution_status_id = e.execution_status_id
                        WHERE e.org_assurance_plan_item_id = @plan_item_id
                          AND e.org_assurance_definition_id = x.definition_id
                          AND e.is_active = 1 AND es.status_code <> N'Cancelled');
    IF @not_plannable IS NOT NULL
    BEGIN
        SET @msg = N'Only an audit with an Active version can be added to a plan. Not Active: ' + @not_plannable + N'.';
        THROW 53933, @msg, 1;
    END

    -- The engagement's first audit is the item's own audit (pre-552 readers).
    SELECT TOP 1 @org_assurance_definition_id = definition_id,
                 @definition_code             = definition_code,
                 @definition_name             = definition_name
      FROM @defs ORDER BY display_order;
    IF NULLIF(LTRIM(RTRIM(@engagement_name)), N'') IS NULL SET @engagement_name = @definition_name;

    -- An audit already started on this engagement cannot be taken out.
    DECLARE @started_removed NVARCHAR(MAX);
    IF @plan_item_id IS NOT NULL
        SELECT @started_removed = STRING_AGG(CONVERT(NVARCHAR(MAX), ISNULL(ed.definition_code, N'?')), N', ')
          FROM grac_practice.org_assurance_engagement_definition ed
         WHERE ed.org_assurance_plan_item_id = @plan_item_id
           AND ed.is_active = 1
           AND ed.org_assurance_definition_id NOT IN (SELECT definition_id FROM @defs)
           AND EXISTS (SELECT 1 FROM grac_practice.org_assurance_execution e
                         JOIN grac_practice.org_assurance_execution_status_master es
                              ON es.org_assurance_execution_status_id = e.execution_status_id
                        WHERE e.org_assurance_plan_item_id = @plan_item_id
                          AND e.org_assurance_definition_id = ed.org_assurance_definition_id
                          AND e.is_active = 1 AND es.status_code <> N'Cancelled');
    IF @started_removed IS NOT NULL
    BEGIN
        SET @msg = N'These audits have been started on this engagement and cannot be removed: ' + @started_removed + N'.';
        THROW 53938, @msg, 1;
    END

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
             notes, engagement_code, engagement_name,             -- 552
             org_assurance_programme_id,                         -- 565
             is_active, entered_by, entered_dt)
        VALUES
            (@plan_id, @organization_id,
             @org_assurance_definition_id, @definition_code, @definition_name,
             ISNULL(@item_order, 0), @scheduled_from, @scheduled_to,
             @assigned_auditor_role_id, @assigned_auditor_role_name,     -- 121
             @assigned_auditor_employee_id, @assigned_auditor_name,
             @assigned_team_name,
             @assigned_department_id, @assigned_department_name,
             @assigned_branch_id, @assigned_branch_name,
             @notes,
             -- 552: plan code + -E01, -E02 ... in the order created
             (SELECT LEFT(p.plan_code, 110) + N'-E'
                     + RIGHT(N'0' + CAST((SELECT COUNT(*) + 1 FROM grac_practice.org_assurance_plan_item x
                                           WHERE x.org_assurance_plan_id = @plan_id) AS NVARCHAR(10)), 2)
                FROM grac_practice.org_assurance_plan p WHERE p.org_assurance_plan_id = @plan_id),
             @engagement_name,
             @programme_id,
             1, @actor, SYSUTCDATETIME());

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
            engagement_name             = @engagement_name,   -- 552
            org_assurance_programme_id  = @programme_id,      -- 565
            updated_by                  = @actor,
            updated_dt                  = SYSUTCDATETIME()
        WHERE org_assurance_plan_item_id = @plan_item_id;

        SET @plan_item_id_out = @plan_item_id;
    END

    -- 552: the engagement's audits -- remove the ones taken out, re-order
    -- the kept ones, add the new ones.
    UPDATE ed
       SET is_active = 0, updated_by = @actor, updated_dt = SYSUTCDATETIME()
      FROM grac_practice.org_assurance_engagement_definition ed
     WHERE ed.org_assurance_plan_item_id = @plan_item_id_out
       AND ed.is_active = 1
       AND ed.org_assurance_definition_id NOT IN (SELECT definition_id FROM @defs);

    UPDATE ed
       SET display_order = x.display_order, definition_code = x.definition_code,
           definition_name = x.definition_name, updated_by = @actor, updated_dt = SYSUTCDATETIME()
      FROM grac_practice.org_assurance_engagement_definition ed
      JOIN @defs x ON x.definition_id = ed.org_assurance_definition_id
     WHERE ed.org_assurance_plan_item_id = @plan_item_id_out
       AND ed.is_active = 1;

    INSERT INTO grac_practice.org_assurance_engagement_definition
        (org_assurance_plan_item_id, organization_id, org_assurance_definition_id,
         definition_code, definition_name, display_order, is_active, entered_by)
    SELECT @plan_item_id_out, @organization_id, x.definition_id,
           x.definition_code, x.definition_name, x.display_order, 1, @actor
      FROM @defs x
     WHERE NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_engagement_definition ed
                        WHERE ed.org_assurance_plan_item_id = @plan_item_id_out
                          AND ed.org_assurance_definition_id = x.definition_id
                          AND ed.is_active = 1);

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
           -- 551 / 552: an audit of the engagement can be planned /
           -- executed -- an Active version, not Retired.
           CAST(CASE WHEN ISNULL(eg.plannable_count, 0) > 0 THEN 1 ELSE 0 END AS BIT) AS DefinitionIsPlannable,
           -- 552: the engagement.
           i.engagement_code             AS EngagementCode,
           -- 565: the programme
           i.org_assurance_programme_id  AS ProgrammeId,
           pg.programme_code             AS ProgrammeCode,
           pg.programme_name             AS ProgrammeName,
           ISNULL(i.engagement_name, i.definition_name) AS EngagementName,
           ISNULL(eg.definition_count, 0) AS DefinitionCount,
           eg.definition_codes           AS DefinitionCodes,
           ISNULL(eg.live_count, 0)      AS ExecutionCount,
           ISNULL(eg.done_count, 0)      AS ExecutionDoneCount,
           CAST(CASE WHEN ISNULL(eg.startable_count, 0) > 0 THEN 1 ELSE 0 END AS BIT) AS CanStart,
           ex.org_assurance_execution_id AS ExecutionId,
           ex.execution_code             AS ExecutionCode,
           ex.status_code                AS ExecutionStatusCode,
           ex.status_name                AS ExecutionStatusName,
           -- 552: rolled up over the engagement's audits.
           CASE WHEN ISNULL(eg.live_count, 0) > 0 AND eg.done_count >= eg.definition_count THEN N'Completed'
                WHEN ISNULL(eg.live_count, 0) > 0 THEN N'InProgress'
                WHEN ps.status_code = N'Closed' OR ISNULL(eg.plannable_count, 0) = 0 THEN N'NotExecuted'
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
    LEFT JOIN grac_practice.org_assurance_plan_programme pg
         ON pg.org_assurance_programme_id = i.org_assurance_programme_id
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
    OUTER APPLY (
        SELECT COUNT(*) AS definition_count,
               STRING_AGG(CONVERT(NVARCHAR(MAX), ISNULL(d2.definition_code, ed.definition_code)), N', ')
                   WITHIN GROUP (ORDER BY ed.display_order) AS definition_codes,
               SUM(lx.live) AS live_count,
               SUM(lx.done) AS done_count,
               SUM(CASE WHEN d2.active_version_id IS NOT NULL AND s2.status_code <> N'Retired' THEN 1 ELSE 0 END) AS plannable_count,
               SUM(CASE WHEN lx.live = 0 AND d2.active_version_id IS NOT NULL AND s2.status_code <> N'Retired' THEN 1 ELSE 0 END) AS startable_count
          FROM grac_practice.org_assurance_engagement_definition ed
          JOIN grac_practice.org_assurance_definition d2
               ON d2.org_assurance_definition_id = ed.org_assurance_definition_id
          JOIN grac_practice.org_assurance_status_master s2
               ON s2.org_assurance_status_id = d2.current_status_id
          CROSS APPLY (
              SELECT ISNULL(MAX(CASE WHEN es2.status_code <> N'Cancelled' THEN 1 ELSE 0 END), 0) AS live,
                     ISNULL(MAX(CASE WHEN es2.status_code IN (N'Approved', N'Closed') THEN 1 ELSE 0 END), 0) AS done
                FROM grac_practice.org_assurance_execution e2
                JOIN grac_practice.org_assurance_execution_status_master es2
                     ON es2.org_assurance_execution_status_id = e2.execution_status_id
               WHERE e2.org_assurance_plan_item_id = ed.org_assurance_plan_item_id
                 AND e2.org_assurance_definition_id = ed.org_assurance_definition_id
                 AND e2.is_active = 1) lx
         WHERE ed.org_assurance_plan_item_id = i.org_assurance_plan_item_id
           AND ed.is_active = 1) eg
    WHERE i.org_assurance_plan_id = @plan_id
      AND i.organization_id       = @organization_id
      AND i.is_active = 1
    ORDER BY i.item_order, i.org_assurance_plan_item_id;
END
GO

-- start / prepare / my list: 555 bodies
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_plan_item_start_execution
    @organization_id  BIGINT,
    @plan_id          BIGINT,
    @plan_item_id     BIGINT,
    @actor            NVARCHAR(100) = 'system',
    @suppress_result  BIT           = 0,      -- 555: My Audits prepare calls it
    @execution_id_out BIGINT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @organization_id IS NULL OR @plan_id IS NULL OR @plan_item_id IS NULL
        THROW 53902, 'organization_id, plan_id and plan_item_id are required.', 1;

    DECLARE @item_plan BIGINT,
            @from DATE, @to DATE,
            @aud_role_id BIGINT, @aud_role_name NVARCHAR(120),
            @aud_emp_id BIGINT, @aud_name NVARCHAR(240),
            @team NVARCHAR(200),
            @branch_id BIGINT, @branch_name NVARCHAR(200);   -- 554
    SELECT @item_plan     = i.org_assurance_plan_id,
           @from          = i.scheduled_from,
           @to            = i.scheduled_to,
           @aud_role_id   = i.assigned_auditor_role_id,
           @aud_role_name = i.assigned_auditor_role_name,
           @aud_emp_id    = i.assigned_auditor_employee_id,
           @aud_name      = i.assigned_auditor_name,
           @team          = i.assigned_team_name,
           @branch_id     = i.assigned_branch_id,     -- 554
           @branch_name   = i.assigned_branch_name
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

    -- The audits to start: active on the engagement, an Active version,
    -- not Retired, and no live execution on this engagement.
    DECLARE @todo TABLE (rn INT IDENTITY(1,1) PRIMARY KEY, definition_id BIGINT NOT NULL, version_id BIGINT NOT NULL);
    INSERT INTO @todo (definition_id, version_id)
    SELECT ed.org_assurance_definition_id, d.active_version_id
      FROM grac_practice.org_assurance_engagement_definition ed
      JOIN grac_practice.org_assurance_definition d
           ON d.org_assurance_definition_id = ed.org_assurance_definition_id
      JOIN grac_practice.org_assurance_status_master s
           ON s.org_assurance_status_id = d.current_status_id
     WHERE ed.org_assurance_plan_item_id = @plan_item_id
       AND ed.is_active = 1
       AND d.active_version_id IS NOT NULL
       AND s.status_code <> N'Retired'
       AND NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_execution e
                         JOIN grac_practice.org_assurance_execution_status_master es
                              ON es.org_assurance_execution_status_id = e.execution_status_id
                        WHERE e.org_assurance_plan_item_id = @plan_item_id
                          AND e.org_assurance_definition_id = ed.org_assurance_definition_id
                          AND e.is_active = 1 AND es.status_code <> N'Cancelled')
     ORDER BY ed.display_order, ed.org_assurance_engagement_definition_id;

    IF NOT EXISTS (SELECT 1 FROM @todo)
        THROW 53936, 'Every audit of this engagement has already been started, or none can be executed (no Active version).', 1;

    DECLARE @started TABLE (execution_id BIGINT NOT NULL);
    DECLARE @n INT = 1, @max INT = (SELECT MAX(rn) FROM @todo),
            @def BIGINT, @ver BIGINT, @eid BIGINT,
            @res BIGINT, @def_code NVARCHAR(80), @msg NVARCHAR(400);   -- 554

    BEGIN TRAN;
    WHILE @n <= @max
    BEGIN
        SELECT @def = definition_id, @ver = version_id FROM @todo WHERE rn = @n;
        SET @eid = NULL;
        SET @res = NULL;
        -- 555: the scope stays LIVE -- the auditor reviews it (narrowed to
        -- the engagement's Branch, 554) and freezes it in My Audits.
        EXEC grac_practice.sp_org_assurance_execution_materialize
             @organization_id     = @organization_id,
             @definition_id       = @def,
             @version_id          = @ver,
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
             @live                = 1,                -- 555
             @execution_id_out    = @eid OUTPUT;
        INSERT INTO @started (execution_id) VALUES (@eid);
        IF @execution_id_out IS NULL SET @execution_id_out = @eid;
        SET @n += 1;
    END
    COMMIT;

    IF ISNULL(@suppress_result, 0) = 1 RETURN;   -- 555

    SELECT e.org_assurance_execution_id AS ExecutionId,
           e.execution_code             AS ExecutionCode,
           e.execution_name             AS ExecutionName,
           e.definition_code            AS DefinitionCode,
           e.total_entity_count         AS TotalEntityCount
      FROM grac_practice.org_assurance_execution e
      JOIN @started s ON s.execution_id = e.org_assurance_execution_id
     ORDER BY e.org_assurance_execution_id;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_my_audits_prepare
    @employee_id BIGINT,
    @actor       NVARCHAR(100) = 'system'
AS
BEGIN
    SET NOCOUNT ON;
    IF @employee_id IS NULL
        THROW 54036, 'employee_id is required.', 1;

    DECLARE @today DATE = CAST(SYSDATETIME() AS DATE);
    DECLARE @due TABLE (rn INT IDENTITY(1,1) PRIMARY KEY, organization_id BIGINT NOT NULL,
                        plan_id BIGINT NOT NULL, plan_item_id BIGINT NOT NULL,
                        engagement_code NVARCHAR(80) NULL);
    INSERT INTO @due (organization_id, plan_id, plan_item_id, engagement_code)
    SELECT i.organization_id, i.org_assurance_plan_id, i.org_assurance_plan_item_id, i.engagement_code
      FROM grac_practice.org_assurance_plan_item i
      JOIN grac_practice.org_assurance_plan p
           ON p.org_assurance_plan_id = i.org_assurance_plan_id
      JOIN grac_practice.org_assurance_plan_status_master ps
           ON ps.org_assurance_plan_status_id = p.status_id
     WHERE i.assigned_auditor_employee_id = @employee_id
       AND i.is_active = 1
       AND p.is_active = 1
       AND ps.status_code IN (N'Approved', N'Active')
       AND i.scheduled_from IS NOT NULL
       AND i.scheduled_from <= @today
       -- an audit of the engagement that can start and has not (the
       -- start procedure's own rule)
       AND EXISTS (
            SELECT 1
              FROM grac_practice.org_assurance_engagement_definition ed
              JOIN grac_practice.org_assurance_definition d
                   ON d.org_assurance_definition_id = ed.org_assurance_definition_id
              JOIN grac_practice.org_assurance_status_master s
                   ON s.org_assurance_status_id = d.current_status_id
             WHERE ed.org_assurance_plan_item_id = i.org_assurance_plan_item_id
               AND ed.is_active = 1
               AND d.active_version_id IS NOT NULL
               AND s.status_code <> N'Retired'
               AND NOT EXISTS (SELECT 1 FROM grac_practice.org_assurance_execution e
                                 JOIN grac_practice.org_assurance_execution_status_master es
                                      ON es.org_assurance_execution_status_id = e.execution_status_id
                                WHERE e.org_assurance_plan_item_id = i.org_assurance_plan_item_id
                                  AND e.org_assurance_definition_id = ed.org_assurance_definition_id
                                  AND e.is_active = 1 AND es.status_code <> N'Cancelled'))
     ORDER BY i.scheduled_from, i.org_assurance_plan_item_id;

    DECLARE @out TABLE (plan_item_id BIGINT, engagement_code NVARCHAR(80), started BIT, message NVARCHAR(2048));
    DECLARE @n INT = 1, @max INT = ISNULL((SELECT MAX(rn) FROM @due), 0),
            @org BIGINT, @plan BIGINT, @item BIGINT, @code NVARCHAR(80), @eid BIGINT;
    WHILE @n <= @max
    BEGIN
        SELECT @org = organization_id, @plan = plan_id, @item = plan_item_id, @code = engagement_code
          FROM @due WHERE rn = @n;
        BEGIN TRY
            SET @eid = NULL;
            EXEC grac_practice.sp_org_assurance_plan_item_start_execution
                 @organization_id  = @org,
                 @plan_id          = @plan,
                 @plan_item_id     = @item,
                 @actor            = @actor,
                 @suppress_result  = 1,
                 @execution_id_out = @eid OUTPUT;
            INSERT INTO @out VALUES (@item, @code, 1, NULL);
        END TRY
        BEGIN CATCH
            IF @@TRANCOUNT > 0 ROLLBACK;
            INSERT INTO @out VALUES (@item, @code, 0, ERROR_MESSAGE());
        END CATCH
        SET @n += 1;
    END

    SELECT plan_item_id AS PlanItemId, engagement_code AS EngagementCode,
           started AS Started, message AS Message
      FROM @out;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_my_audit_list
    @employee_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF @employee_id IS NULL
        THROW 54036, 'employee_id is required.', 1;

    DECLARE @today DATE = CAST(SYSDATETIME() AS DATE);

    SELECT i.organization_id               AS OrganizationId,
           o.organization_name             AS OrganizationName,
           p.org_assurance_plan_id         AS PlanId,
           p.plan_code                     AS PlanCode,
           p.plan_name                     AS PlanName,
           i.org_assurance_plan_item_id    AS PlanItemId,
           i.engagement_code               AS EngagementCode,
           i.engagement_name               AS EngagementName,
           i.assigned_branch_id            AS BranchId,
           i.assigned_branch_name          AS BranchName,
           i.scheduled_from                AS ScheduledFrom,
           i.scheduled_to                  AS ScheduledTo,
           d.org_assurance_definition_id   AS DefinitionId,
           d.definition_code               AS DefinitionCode,
           d.definition_name               AS DefinitionName,
           ex.org_assurance_execution_id   AS ExecutionId,
           ex.execution_code               AS ExecutionCode,
           ex.status_code                  AS ExecutionStatusCode,
           ex.status_name                  AS ExecutionStatusName,
           ex.scope_frozen_at              AS ScopeFrozenAt,
           ex.total_entity_count           AS TotalEntityCount,
           ex.completed_entity_count       AS CompletedEntityCount,
           CASE WHEN ex.org_assurance_execution_id IS NULL
                     THEN CASE WHEN i.scheduled_from > @today THEN N'Upcoming' ELSE N'Ready' END
                WHEN ex.status_code = N'Cancelled'    THEN N'Cancelled'
                WHEN ex.scope_frozen_at IS NULL       THEN N'ScopeLive'
                WHEN ex.status_code IN (N'Planned', N'InProgress') THEN N'InProgress'
                ELSE N'Done' END           AS AuditState
      FROM grac_practice.org_assurance_engagement_definition ed
      JOIN grac_practice.org_assurance_plan_item i
           ON i.org_assurance_plan_item_id = ed.org_assurance_plan_item_id
      JOIN grac_practice.org_assurance_plan p
           ON p.org_assurance_plan_id = i.org_assurance_plan_id
      JOIN grac_practice.org_assurance_plan_status_master ps
           ON ps.org_assurance_plan_status_id = p.status_id
      JOIN grac_practice.org_assurance_definition d
           ON d.org_assurance_definition_id = ed.org_assurance_definition_id
      JOIN grac_practice.organization o
           ON o.organization_id = i.organization_id
      OUTER APPLY (
          SELECT TOP 1 e.org_assurance_execution_id, e.execution_code, es.status_code, es.status_name,
                       e.scope_frozen_at, e.total_entity_count, e.completed_entity_count
            FROM grac_practice.org_assurance_execution e
            JOIN grac_practice.org_assurance_execution_status_master es
                 ON es.org_assurance_execution_status_id = e.execution_status_id
           WHERE e.org_assurance_plan_item_id = ed.org_assurance_plan_item_id
             AND e.org_assurance_definition_id = ed.org_assurance_definition_id
             AND e.is_active = 1
           ORDER BY CASE WHEN es.status_code = N'Cancelled' THEN 1 ELSE 0 END,
                    e.org_assurance_execution_id DESC) ex
     WHERE i.assigned_auditor_employee_id = @employee_id
       AND i.is_active  = 1
       AND ed.is_active = 1
       AND p.is_active  = 1
       AND ps.status_code IN (N'Approved', N'Active', N'Closed')
     ORDER BY i.scheduled_from, i.engagement_code, ed.display_order, ed.org_assurance_engagement_definition_id;
END
GO

-- holder list: 553 body
CREATE OR ALTER PROCEDURE grac_practice.sp_org_responsibility_holder_list
    @organization_id     BIGINT,
    @responsibility_code NVARCHAR(60)
AS
BEGIN
    SET NOCOUNT ON;
    IF @organization_id IS NULL OR NULLIF(LTRIM(RTRIM(@responsibility_code)), N'') IS NULL
        THROW 55100, 'organization_id and responsibility_code are required.', 1;

    DECLARE @active_record_status_id INT = (
        SELECT TOP 1 record_status_id
        FROM grac_practice.record_status_master
        WHERE status_code = 'ACTIVE' OR status_name = 'Active'
        ORDER BY record_status_id);
    IF @active_record_status_id IS NULL SET @active_record_status_id = 1;

    SELECT e.employee_id   AS EmployeeId,
           e.employee_code AS EmployeeCode,
           e.employee_name AS EmployeeName,
           e.designation   AS Designation,
           r.role_id       AS RoleId,
           r.role_name     AS RoleName
    FROM grac_practice.organization_employee e
    JOIN grac_practice.organization_role r
         ON r.role_id = e.role_id
    WHERE e.organization_id  = @organization_id
      AND e.status           = N'Active'
      AND e.record_status_id = @active_record_status_id
      AND r.record_status_id = @active_record_status_id
      AND EXISTS (SELECT 1
                    FROM grac_practice.organization_role_responsibility x
                    JOIN grac_practice.role_responsibility_master m
                         ON m.role_responsibility_id = x.role_responsibility_id
                   WHERE x.role_id = r.role_id
                     AND x.is_active = 1
                     AND m.is_active = 1
                     AND m.responsibility_code = @responsibility_code)
    ORDER BY e.employee_name, e.employee_id;
END
GO

-- engagement progress: 565 body
CREATE OR ALTER FUNCTION grac_practice.fn_org_assurance_engagement_progress(@plan_id BIGINT)
RETURNS TABLE
AS
RETURN
    SELECT i.org_assurance_plan_item_id AS plan_item_id,
           i.org_assurance_programme_id AS programme_id,
           x.definition_count,
           x.started_count,
           x.done_count,
           CASE WHEN x.started_count > 0 AND x.done_count >= x.definition_count THEN N'Completed'
                WHEN x.started_count > 0 THEN N'InProgress'
                ELSE N'Planned' END AS progress_status
      FROM grac_practice.org_assurance_plan_item i
     CROSS APPLY (
        SELECT COUNT(*)                AS definition_count,
               ISNULL(SUM(lx.live), 0) AS started_count,
               ISNULL(SUM(lx.done), 0) AS done_count
          FROM grac_practice.org_assurance_engagement_definition ed
         CROSS APPLY (
            SELECT ISNULL(MAX(CASE WHEN es.status_code <> N'Cancelled' THEN 1 ELSE 0 END), 0) AS live,
                   ISNULL(MAX(CASE WHEN es.status_code IN (N'Approved', N'Closed') THEN 1 ELSE 0 END), 0) AS done
              FROM grac_practice.org_assurance_execution e
              JOIN grac_practice.org_assurance_execution_status_master es
                   ON es.org_assurance_execution_status_id = e.execution_status_id
             WHERE e.org_assurance_plan_item_id = ed.org_assurance_plan_item_id
               AND e.org_assurance_definition_id = ed.org_assurance_definition_id
               AND e.is_active = 1) lx
         WHERE ed.org_assurance_plan_item_id = i.org_assurance_plan_item_id
           AND ed.is_active = 1) x
     WHERE i.org_assurance_plan_id = @plan_id
       AND i.is_active = 1;
GO

IF OBJECT_ID('grac_practice.fn_org_assurance_engagement_rows') IS NOT NULL DROP FUNCTION grac_practice.fn_org_assurance_engagement_rows;
IF OBJECT_ID('grac_practice.fn_org_assurance_engagement_status') IS NOT NULL DROP FUNCTION grac_practice.fn_org_assurance_engagement_status;
IF OBJECT_ID('grac_practice.fn_org_responsibility_holder') IS NOT NULL DROP FUNCTION grac_practice.fn_org_responsibility_holder;
GO
PRINT '566 rolled back: procedures back to 553 / 555 / 565; engagement procedures and functions dropped; Audit Engagements menu Inactive; tables / columns kept (an independent engagement keeps a NULL plan).';
GO
