-- =====================================================================
-- 526 ROLLBACK  Task review / approval cycle
--
-- Restores sp_task_complete (200), sp_task_list (414) and
-- sp_schedule_obligation_tasks_generate (459) verbatim, drops the five
-- 526 procedures, deactivates the transition rules and the Pending
-- Approval status 526 seeded, and drops the 526 columns.
--
-- REFUSES while any task is in the cycle (review_stage set): decide or
-- return those tasks first, or they would be stranded in Pending Review /
-- Pending Approval with no way out. The reviewer / approver chosen on
-- tasks and schedules are lost.
-- Restart the Api afterwards (TaskService probes procedure parameters).
-- ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF COL_LENGTH('grac_practice.practice_task','review_stage') IS NOT NULL
   AND EXISTS (SELECT 1 FROM grac_practice.practice_task WHERE review_stage IS NOT NULL)
BEGIN
    PRINT 'ABORT (526 rollback): tasks are waiting for review or approval. Approve or return them first. Nothing was changed.';
    SET NOEXEC ON;
END
GO

DROP PROCEDURE IF EXISTS grac_practice.sp_task_review_decide;
DROP PROCEDURE IF EXISTS grac_practice.sp_task_review_get;
DROP PROCEDURE IF EXISTS grac_practice.sp_task_review_settings_set;
DROP PROCEDURE IF EXISTS grac_practice.sp_schedule_rule_review_save;
DROP PROCEDURE IF EXISTS grac_practice.sp_schedule_rule_review_get;
GO

UPDATE grac_practice.entity_state_transition_rule
   SET is_active = 0, updated_by = N'rollback-526', updated_dt = SYSUTCDATETIME()
 WHERE entered_by = N'seed-526';
UPDATE grac_practice.entity_status_master
   SET is_active = 0, updated_by = N'rollback-526', updated_dt = SYSUTCDATETIME()
 WHERE entity_type = N'Task' AND status_code = N'PendingApproval' AND entered_by = N'seed-526';
GO

-- sp_task_complete (200 body)
CREATE OR ALTER PROCEDURE grac_practice.sp_task_complete
    @task_id             BIGINT,
    @completion_remark   NVARCHAR(MAX) = NULL,
    @actor_employee_id   BIGINT        = NULL,
    @actor_role_code     NVARCHAR(60)  = NULL,
    @caller_display_name NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @task_id IS NULL
        THROW 55690, 'sp_task_complete: task_id is required.', 1;

    DECLARE @closed_at DATETIME2, @parent_task_id BIGINT, @title NVARCHAR(250),
            @found BIT = 0, @source_type NVARCHAR(40), @source_record_id BIGINT;
    SELECT @closed_at        = closed_at,
           @parent_task_id   = parent_task_id,
           @title            = subject_title,
           @source_type      = source_type_code,
           @source_record_id = source_record_id,
           @found            = 1
      FROM grac_practice.practice_task WHERE task_id = @task_id;

    IF @found = 0
        THROW 55691, 'sp_task_complete: task not found.', 1;

    IF @closed_at IS NOT NULL
        THROW 55692, 'sp_task_complete: the task is already completed.', 1;

    -- ---- Mandatory-child gate (BRD Sec 12) -----------------------------
    DECLARE @elig TABLE (
        TaskId BIGINT, IsEligible BIT, Reason NVARCHAR(300),
        ChildCount INT, MandatoryChildCount INT,
        MandatoryChildCompletedCount INT, MandatoryChildOpenCount INT);

    INSERT @elig EXEC grac_practice.sp_task_completion_eligibility @task_id = @task_id;

    DECLARE @eligible BIT, @reason NVARCHAR(300);
    SELECT TOP 1 @eligible = IsEligible, @reason = Reason FROM @elig;

    IF @eligible = 0
    BEGIN
        DECLARE @gate_msg NVARCHAR(400) =
            CONCAT(N'sp_task_complete: task ', CAST(@task_id AS NVARCHAR(20)),
                   N' is not eligible for completion. ', @reason);
        THROW 55693, @gate_msg, 1;
    END

    BEGIN TRAN;

    EXEC grac_practice.sp_task_close
         @task_id           = @task_id,
         @actor_employee_id = @actor_employee_id,
         @actor_role_code   = @actor_role_code,
         @reason_code       = N'TASK_COMPLETED',
         @reason_text       = @completion_remark;

    UPDATE grac_practice.practice_task
       SET completed_by_employee_id = @actor_employee_id,
           completed_dt             = SYSUTCDATETIME(),
           updated_by               = @caller_display_name,
           updated_dt               = SYSUTCDATETIME()
     WHERE task_id = @task_id;

    EXEC grac_practice.sp_task_activity_add
         @task_id             = @task_id,
         @activity_type_code  = N'Completed',
         @remark              = @completion_remark,
         @actor_employee_id   = @actor_employee_id,
         @caller_display_name = @caller_display_name;

    IF @parent_task_id IS NOT NULL
    BEGIN
        EXEC grac_practice.sp_task_activity_add
             @task_id             = @parent_task_id,
             @activity_type_code  = N'ChildCompleted',
             @remark              = @completion_remark,
             @to_value            = @title,
             @actor_employee_id   = @actor_employee_id,
             @caller_display_name = @caller_display_name;

        DECLARE @pelig TABLE (
            TaskId BIGINT, IsEligible BIT, Reason NVARCHAR(300),
            ChildCount INT, MandatoryChildCount INT,
            MandatoryChildCompletedCount INT, MandatoryChildOpenCount INT);

        INSERT @pelig EXEC grac_practice.sp_task_completion_eligibility @task_id = @parent_task_id;

        IF EXISTS (SELECT 1 FROM @pelig WHERE IsEligible = 1)
            EXEC grac_practice.sp_task_activity_add
                 @task_id             = @parent_task_id,
                 @activity_type_code  = N'ParentEligibleForCompletion',
                 @remark              = N'All mandatory child tasks are complete. The parent owner can now confirm completion of the overall objective.',
                 @actor_employee_id   = @actor_employee_id,
                 @caller_display_name = @caller_display_name;
    END

    COMMIT;

    -- ---- NEW in 200: upstream synchronisation (BRD Sec 14) --------------
    -- Reports; never decides. Nothing below writes to a source table's
    -- own status.
    DECLARE @sync_status NVARCHAR(30) = NULL;

    IF @source_type IS NOT NULL AND @source_record_id IS NOT NULL
    BEGIN
        BEGIN TRY
            EXEC grac_practice.sp_task_source_sync
                 @source_type_code    = @source_type,
                 @source_record_id    = @source_record_id,
                 @caller_display_name = @caller_display_name,
                 @action_status_code  = @sync_status OUTPUT;
        END TRY
        BEGIN CATCH
            DECLARE @sync_warn NVARCHAR(4000) = ERROR_MESSAGE();
            PRINT CONCAT(N'sp_task_complete: upstream sync warning: ', @sync_warn);
        END CATCH
    END

    SELECT @task_id             AS TaskId,
           N'Completed'         AS StatusCode,
           @parent_task_id      AS ParentTaskId,
           @source_type         AS SourceTypeCode,
           @source_record_id    AS SourceRecordId,
           @sync_status         AS SourceActionStatusCode;
END;
GO

-- sp_task_list (414 body)
CREATE OR ALTER PROCEDURE grac_practice.sp_task_list
    @organization_id         BIGINT        = NULL,
    @assigned_to_employee_id BIGINT        = NULL,
    @task_type_code          NVARCHAR(60)  = NULL,
    @status_code             NVARCHAR(60)  = NULL,   -- 'OpenSet' for non-terminal, else specific
    @overdue_only            BIT           = 0,
    @search                  NVARCHAR(200) = NULL,
    @page                    INT           = 1,
    @page_size               INT           = 25,
    @parent_task_id          BIGINT        = NULL,   -- children of one parent
    @include_children        BIT           = 0,
    @sla_status_code         NVARCHAR(30)  = NULL,   -- OnTrack/DueSoon/DueToday/Breached/Extended/Completed
    @source_type_code        NVARCHAR(40)  = NULL,
    @source_record_id        BIGINT        = NULL,
    @priority                NVARCHAR(30)  = NULL,
    -- 414: dashboard drill-down. NULL = no opinion.
    --   @no_owner  1 = assigned_to_employee_id IS NULL
    --   @min_age_days / @max_age_days  one ageing band, age measured
    --              from the SLA baseline COALESCE(start_date, entered_dt)
    @no_owner                BIT           = NULL,
    @min_age_days            INT           = NULL,
    @max_age_days            INT           = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @page IS NULL OR @page < 1 SET @page = 1;
    IF @page_size IS NULL OR @page_size < 1 SET @page_size = 25;
    IF @page_size > 200 SET @page_size = 200;

    -- Asking for one parent's children implies you want children.
    IF @parent_task_id IS NOT NULL SET @include_children = 1;

    DECLARE @filtered TABLE (task_id BIGINT PRIMARY KEY, sort_due DATETIME2);

    INSERT INTO @filtered (task_id, sort_due)
    SELECT v.task_id, v.sla_due_at
      FROM grac_practice.vw_pm_practice_task v
     WHERE (@organization_id IS NULL         OR v.organization_id = @organization_id)
       AND (@assigned_to_employee_id IS NULL OR v.assigned_to_employee_id = @assigned_to_employee_id)
       -- Migration 253: the Custom Tasks tab is also the home for gap
       -- remediation work, which opens as 'Rectification'.
       AND (@task_type_code IS NULL
            OR v.task_type_code = @task_type_code
            OR (@task_type_code = N'Custom' AND v.task_type_code = N'Rectification'))
       AND (
             @status_code IS NULL
          OR (@status_code = N'OpenSet' AND v.current_status_is_terminal = 0)
          OR v.current_status_code = @status_code
           )
       AND (@overdue_only = 0 OR v.is_overdue = 1)
       AND (@priority IS NULL                OR v.priority = @priority)
       AND (@sla_status_code IS NULL         OR v.sla_status_code = @sla_status_code)
       AND (@source_type_code IS NULL        OR v.source_type_code = @source_type_code)
       AND (@source_record_id IS NULL        OR v.source_record_id = @source_record_id)
       AND (@parent_task_id IS NULL          OR v.parent_task_id = @parent_task_id)
       AND (@include_children = 1            OR v.parent_task_id IS NULL)
       -- 414
       AND (ISNULL(@no_owner, 0) = 0         OR v.assigned_to_employee_id IS NULL)
       AND (@min_age_days IS NULL
            OR DATEDIFF(DAY, COALESCE(v.start_date, v.entered_dt), SYSUTCDATETIME()) >= @min_age_days)
       AND (@max_age_days IS NULL
            OR DATEDIFF(DAY, COALESCE(v.start_date, v.entered_dt), SYSUTCDATETIME()) <= @max_age_days)
       AND (@search IS NULL
            OR v.subject_title LIKE N'%' + @search + N'%'
            OR v.subject_description LIKE N'%' + @search + N'%'
            OR v.task_number LIKE N'%' + @search + N'%');

    -- Result-set #1 -- count + paging metadata (unchanged shape)
    SELECT COUNT_BIG(*) AS TotalCount,
           @page        AS PageNumber,
           @page_size   AS PageSize
      FROM @filtered;

    -- Result-set #2 -- the current page
    SELECT v.*
      FROM @filtered f
      JOIN grac_practice.vw_pm_practice_task v ON v.task_id = f.task_id
     ORDER BY CASE WHEN f.sort_due IS NULL THEN 1 ELSE 0 END,
              f.sort_due ASC,
              f.task_id DESC
     OFFSET (@page - 1) * @page_size ROWS
     FETCH NEXT @page_size ROWS ONLY;
END;
GO

-- sp_schedule_obligation_tasks_generate (459 body)
CREATE OR ALTER PROCEDURE grac_practice.sp_schedule_obligation_tasks_generate
    @organization_id BIGINT        = NULL,   -- NULL = every organisation
    @run_date        DATE          = NULL,   -- NULL = today (UTC)
    @actor           NVARCHAR(100) = N'scheduler',
    @tasks_created   INT           = NULL OUTPUT,
    @error_count     INT           = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT OFF;   -- per-row TRY/CATCH must survive a failed task

    DECLARE @today DATE = ISNULL(@run_date, CAST(SYSUTCDATETIME() AS DATE));
    SET @tasks_created = 0;
    SET @error_count   = 0;

    DECLARE @lock INT;
    EXEC @lock = sp_getapplock @Resource = N'grac_practice.schedule_obligation_tasks', @LockMode = N'Exclusive',
                               @LockOwner = N'Session', @LockTimeout = 0;
    IF @lock < 0
    BEGIN
        SELECT @today AS RunDate, N'SKIPPED' AS Result, 0 AS TasksCreated, 0 AS ErrorCount;
        RETURN;
    END

    BEGIN TRY
        -- ---- Active rules with a periodic frequency ---------------------
        CREATE TABLE #rule (
            schedule_rule_id BIGINT NOT NULL PRIMARY KEY,
            organization_id  BIGINT NOT NULL,
            practice_instance_id BIGINT NOT NULL,
            practice_instance_obligation_id BIGINT NULL,
            anchor_date DATE NOT NULL,
            end_date    DATE NULL,
            freq_value  INT NOT NULL,
            freq_unit   NVARCHAR(20) NOT NULL);

        INSERT #rule
        SELECT r.schedule_rule_id, r.organization_id, r.practice_instance_id,
               r.practice_instance_obligation_id, r.anchor_date, r.end_date,
               fm.frequency_value, fm.frequency_unit
          FROM grac_practice.assurance_schedule_rule r
          JOIN grac_practice.frequency_master fm ON fm.frequency_id = r.frequency_id
          JOIN grac_practice.practice_instance pi ON pi.practice_instance_id = r.practice_instance_id
          LEFT JOIN grac_practice.practice_instance_obligation pio
                 ON pio.practice_instance_obligation_id = r.practice_instance_obligation_id
         WHERE r.status = N'Active' AND r.is_active = 1
           AND (@organization_id IS NULL OR r.organization_id = @organization_id)
           AND pi.status = N'Active'
           AND (r.practice_instance_obligation_id IS NULL OR pio.status = N'Active')
           AND fm.frequency_value > 0
           AND fm.frequency_unit IS NOT NULL AND LEN(fm.frequency_unit) > 0
           AND r.anchor_date <= @today
           AND (r.end_date IS NULL OR r.end_date >= @today);

        -- ---- Natural occurrences on @today -----------------------------
        CREATE TABLE #due (schedule_rule_id BIGINT NOT NULL, occurrence_date DATE NOT NULL);

        -- Day / Week: arithmetic (a daily rule can be thousands of steps old).
        INSERT #due (schedule_rule_id, occurrence_date)
        SELECT schedule_rule_id, @today
          FROM #rule
         WHERE freq_unit IN (N'Day', N'Week')
           AND DATEDIFF(DAY, anchor_date, @today)
               % (CASE WHEN freq_unit = N'Week' THEN freq_value * 7 ELSE freq_value END) = 0;

        -- Month / Year / anything else (the C# falls back to AddMonths):
        -- stepped one at a time, as AddMonths/AddYears are, so day-of-month
        -- clamping drifts identically.
        ;WITH step AS (
            SELECT schedule_rule_id, freq_value, freq_unit, anchor_date AS occ
              FROM #rule
             WHERE freq_unit NOT IN (N'Day', N'Week')
            UNION ALL
            SELECT schedule_rule_id, freq_value, freq_unit,
                   CASE WHEN freq_unit = N'Year' THEN DATEADD(YEAR,  freq_value, occ)
                        ELSE                          DATEADD(MONTH, freq_value, occ) END
              FROM step
             WHERE occ < @today
        )
        INSERT #due (schedule_rule_id, occurrence_date)
        SELECT schedule_rule_id, occ FROM step WHERE occ = @today
        OPTION (MAXRECURSION 5000);

        -- ---- Overrides (same rules as the calendar) --------------------
        DELETE d
          FROM #due d
         WHERE EXISTS (SELECT 1 FROM grac_practice.assurance_schedule_override o
                        WHERE o.schedule_rule_id = d.schedule_rule_id
                          AND o.status = N'Active'
                          AND o.override_type IN (N'Skipped', N'Moved')
                          AND o.original_date = d.occurrence_date);

        INSERT #due (schedule_rule_id, occurrence_date)
        SELECT DISTINCT o.schedule_rule_id, @today
          FROM grac_practice.assurance_schedule_override o
          JOIN #rule r ON r.schedule_rule_id = o.schedule_rule_id
         WHERE o.status = N'Active'
           AND ((o.override_type = N'Moved' AND o.new_date = @today)
             OR (o.override_type = N'Added' AND COALESCE(o.new_date, o.original_date) = @today))
           AND NOT EXISTS (SELECT 1 FROM #due d WHERE d.schedule_rule_id = o.schedule_rule_id);

        -- ---- Claim (once per rule and date, ever) ------------------------
        INSERT grac_practice.schedule_occurrence_task
              (organization_id, schedule_rule_id, occurrence_date, practice_instance_id,
               practice_instance_obligation_id, entered_by)
        SELECT r.organization_id, d.schedule_rule_id, d.occurrence_date, r.practice_instance_id,
               r.practice_instance_obligation_id, @actor
          FROM (SELECT DISTINCT schedule_rule_id, occurrence_date FROM #due) d
          JOIN #rule r ON r.schedule_rule_id = d.schedule_rule_id
         WHERE NOT EXISTS (SELECT 1 FROM grac_practice.schedule_occurrence_task x
                            WHERE x.schedule_rule_id = d.schedule_rule_id
                              AND x.occurrence_date  = d.occurrence_date);

        -- ---- Raise a task for every claimed row of the day without one ---
        DECLARE @occ BIGINT, @org BIGINT, @pi BIGINT, @practice BIGINT, @pio BIGINT,
                @owner BIGINT, @crit NVARCHAR(30), @title NVARCHAR(250), @descr NVARCHAR(MAX),
                @ref NVARCHAR(200), @target DATETIME2, @start DATETIME2, @tid BIGINT,
                @date_text NVARCHAR(20);

        DECLARE c CURSOR LOCAL FAST_FORWARD FOR
            SELECT x.occurrence_task_id
              FROM grac_practice.schedule_occurrence_task x
             WHERE x.occurrence_date = @today
               AND x.task_id IS NULL
               AND (@organization_id IS NULL OR x.organization_id = @organization_id)
             ORDER BY x.occurrence_task_id;
        OPEN c;
        FETCH NEXT FROM c INTO @occ;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            BEGIN TRY
                SET @tid = NULL;
                SET @date_text = CONVERT(NVARCHAR(20), @today, 106);   -- 06 Oct 2026
                SELECT @org      = x.organization_id,
                       @pi       = x.practice_instance_id,
                       @pio      = x.practice_instance_obligation_id,
                       @practice = pi.practice_id,
                       @crit     = pi.criticality,
                       @owner    = CASE WHEN EXISTS (SELECT 1 FROM grac_practice.organization_employee e
                                                      WHERE e.employee_id = pi.primary_owner_id
                                                        AND e.organization_id = x.organization_id
                                                        AND ISNULL(e.status, N'Active') = N'Active')
                                        THEN pi.primary_owner_id END,
                       @title    = LEFT(CONCAT(COALESCE(NULLIF(LTRIM(RTRIM(pio.obligation_name)), N''),
                                                        pi.instance_name),
                                               N' - due ', @date_text), 250),
                       -- 459: the task description is the OBLIGATION's own
                       -- description -- the organisation's copy for a
                       -- published obligation (fn_org_requirement_obligation),
                       -- obligation_description for one the organisation
                       -- added. Only an obligation with no description falls
                       -- back to the 449 summary, so it is never blank.
                       @descr    = COALESCE(
                                       NULLIF(LTRIM(RTRIM(pio.obligation_description)), N''),
                                       NULLIF(LTRIM(RTRIM(od.obligation_text)), N''),
                                       CONCAT(N'Scheduled ', COALESCE(r.schedule_kind, N'Assurance'),
                                          N' obligation due ', @date_text, N'.', CHAR(13), CHAR(10),
                                          N'Practice instance: ', pi.instance_code, N' - ', pi.instance_name, CHAR(13), CHAR(10),
                                          N'Frequency: ', fm.frequency_name,
                                          CASE WHEN pio.responsibility IS NULL THEN N''
                                               ELSE CONCAT(CHAR(13), CHAR(10), N'Responsibility: ', pio.responsibility) END)),
                       @ref      = CONCAT(N'Schedule rule ', x.schedule_rule_id, N' / ', CONVERT(NVARCHAR(10), x.occurrence_date, 23))
                  FROM grac_practice.schedule_occurrence_task x
                  JOIN grac_practice.assurance_schedule_rule r ON r.schedule_rule_id = x.schedule_rule_id
                  JOIN grac_practice.frequency_master fm ON fm.frequency_id = r.frequency_id
                  JOIN grac_practice.practice_instance pi ON pi.practice_instance_id = x.practice_instance_id
                  LEFT JOIN grac_practice.practice_instance_obligation pio
                         ON pio.practice_instance_obligation_id = x.practice_instance_obligation_id
                  OUTER APPLY (SELECT TOP 1 o.obligation_text
                                 FROM grac_practice.fn_org_requirement_obligation(x.organization_id) o
                                WHERE o.obligation_id = pio.obligation_id
                                ORDER BY CASE WHEN o.status = N'Active' THEN 0 ELSE 1 END) od
                 WHERE x.occurrence_task_id = @occ;

                SET @start  = CAST(@today AS DATETIME2);
                SET @target = DATEADD(SECOND, 86399, CAST(@today AS DATETIME2));   -- end of the due day

                EXEC grac_practice.sp_task_open
                     @organization_id          = @org,
                     @task_type_code           = N'ScheduledObligation',
                     @subject_entity_type      = N'ScheduleOccurrence',
                     @subject_entity_id        = @occ,
                     @subject_title            = @title,
                     @subject_description      = @descr,
                     @linked_practice_id       = @practice,
                     @linked_instance_id       = @pi,
                     @criticality              = @crit,
                     @assigned_to_employee_id  = @owner,
                     @related_entity_type_code = N'PracticeInstance',
                     @related_record_id        = @pi,
                     @start_date               = @start,
                     @target_date              = @target,
                     @source_type_code         = N'Schedule',
                     @source_record_id         = @occ,
                     @source_reference         = @ref,
                     @resolve_owner            = 1,
                     @task_id                  = @tid OUTPUT;

                UPDATE grac_practice.schedule_occurrence_task
                   SET task_id = @tid, task_error = NULL, updated_by = @actor, updated_dt = SYSUTCDATETIME()
                 WHERE occurrence_task_id = @occ;
                SET @tasks_created = @tasks_created + 1;
            END TRY
            BEGIN CATCH
                IF XACT_STATE() <> 0 ROLLBACK;
                SET @error_count = @error_count + 1;
                UPDATE grac_practice.schedule_occurrence_task
                   SET task_error = LEFT(ERROR_MESSAGE(), 1000), updated_by = @actor, updated_dt = SYSUTCDATETIME()
                 WHERE occurrence_task_id = @occ;
            END CATCH
            FETCH NEXT FROM c INTO @occ;
        END
        CLOSE c;
        DEALLOCATE c;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK;
        EXEC sp_releaseapplock @Resource = N'grac_practice.schedule_obligation_tasks', @LockOwner = N'Session';
        THROW;
    END CATCH

    EXEC sp_releaseapplock @Resource = N'grac_practice.schedule_obligation_tasks', @LockOwner = N'Session';

    SELECT @today AS RunDate, N'OK' AS Result, @tasks_created AS TasksCreated, @error_count AS ErrorCount;
END;
GO
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ix_pm_practice_task_review_stage'
            AND object_id = OBJECT_ID('grac_practice.practice_task'))
    DROP INDEX ix_pm_practice_task_review_stage ON grac_practice.practice_task;
IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_practice_task_review_stage')
    ALTER TABLE grac_practice.practice_task DROP CONSTRAINT ck_pm_practice_task_review_stage;
GO
IF COL_LENGTH('grac_practice.practice_task','review_submitted_remark') IS NOT NULL
    ALTER TABLE grac_practice.practice_task DROP COLUMN review_submitted_remark;
IF COL_LENGTH('grac_practice.practice_task','review_submitted_dt') IS NOT NULL
    ALTER TABLE grac_practice.practice_task DROP COLUMN review_submitted_dt;
IF COL_LENGTH('grac_practice.practice_task','review_submitted_by_employee_id') IS NOT NULL
    ALTER TABLE grac_practice.practice_task DROP COLUMN review_submitted_by_employee_id;
IF COL_LENGTH('grac_practice.practice_task','review_stage') IS NOT NULL
    ALTER TABLE grac_practice.practice_task DROP COLUMN review_stage;
IF COL_LENGTH('grac_practice.practice_task','approver_employee_id') IS NOT NULL
    ALTER TABLE grac_practice.practice_task DROP COLUMN approver_employee_id;
IF COL_LENGTH('grac_practice.practice_task','reviewer_employee_id') IS NOT NULL
    ALTER TABLE grac_practice.practice_task DROP COLUMN reviewer_employee_id;
IF COL_LENGTH('grac_practice.assurance_schedule_rule','approver_employee_id') IS NOT NULL
    ALTER TABLE grac_practice.assurance_schedule_rule DROP COLUMN approver_employee_id;
IF COL_LENGTH('grac_practice.assurance_schedule_rule','reviewer_employee_id') IS NOT NULL
    ALTER TABLE grac_practice.assurance_schedule_rule DROP COLUMN reviewer_employee_id;
GO

PRINT '526 rollback complete. Restart the Api.';
GO
SET NOEXEC OFF;
GO
