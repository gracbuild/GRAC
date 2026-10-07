-- =====================================================================
-- 449  Scheduled obligations raise a Task Centre task on the due date
--
-- REQUEST (2026-10-06)
-- --------------------
--   Obligations scheduled on Operationalize (Execution, and Assurance in
--   Scheduled trigger mode) appeared on the Assurance Calendar but never
--   produced a task: occurrences are computed at read time (028, "store
--   only overrides") and nothing called sp_task_open for them. A task is
--   now raised for each occurrence ON ITS DUE DATE -- not ahead of time,
--   so a daily obligation adds one task a day, not a backlog.
--
-- WHAT THIS DOES
-- --------------
--   1. Task type ScheduledObligation ("Scheduled Obligation").
--   2. Task Centre source "Schedule" (ck_pm_practice_task_source_type
--      widened the 215 / 438 way: every existing value kept, WITH NOCHECK).
--   3. schedule_occurrence_task -- one row per schedule rule and
--      occurrence date (UNIQUE), holding the task it raised or the error.
--      This is the duplicate guard: a date is claimed once, ever.
--   4. sp_schedule_obligation_tasks_generate -- for @run_date (default:
--      today, UTC -- the same "today" the calendar uses for Past /
--      Upcoming and the asset scheduler uses):
--        * occurrences of every active rule that fall on that date,
--          computed EXACTLY as PracticeRepositoryService.
--          QueryCalendarEventsAsync does: anchor_date stepped by the
--          frequency (Day n, Week n*7, Month n, Year n, iteratively, so a
--          31st anchor drifts the same way AddMonths does), up to end_date;
--        * calendar overrides: Skipped and Moved remove the original date,
--          Moved adds its new_date, Added adds its date;
--        * only Active rules (status + is_active), Active instances and
--          Active adopted obligations;
--        * one task per claimed row: owner = the instance's primary owner
--          (if an active employee of the organisation), otherwise the
--          normal sp_task_owner_resolve ladder; target date = end of the
--          due day; linked to the instance and its practice.
--      A row whose task failed keeps task_error and is retried on the next
--      pass of the same day. Serialised by an application lock, so a second
--      API instance skips instead of raising twice.
--   5. sp_task_centre_source_counts -- 438's body + "Schedule".
--
-- 438 (asset activities) IS NOT REQUIRED -- 449 runs on a database that
-- has no asset module (e.g. UAT). If 438 is run later on such a database,
-- re-run 449 afterwards: 438 re-issues sp_task_centre_source_counts
-- without 'Schedule' (the source filter would lose its count, nothing
-- else). 449 is re-runnable.
--
-- RUN BY: TaskNotificationWorker (ScheduledObligationTasksEnabled, every
--   ScheduledObligationTasksIntervalMinutes, default 60). By hand / SQL
--   Agent: EXEC grac_practice.sp_schedule_obligation_tasks_generate;
--   A missed day is NOT back-filled automatically (the request is "on the
--   due date"); pass @run_date to raise a specific past day on purpose.
--
-- ERROR NUMBERS: none thrown (per-row failures are recorded, not raised).
-- DEPENDS ON: 028, 196, 215, 336-338. (438 optional -- see above.)
-- Rollback: 449_scheduled_obligation_tasks_rollback.sql
-- Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.assurance_schedule_rule','U') IS NULL
   OR OBJECT_ID('grac_practice.assurance_schedule_override','U') IS NULL
   OR COL_LENGTH('grac_practice.assurance_schedule_rule','practice_instance_obligation_id') IS NULL
   OR COL_LENGTH('grac_practice.assurance_schedule_rule','schedule_kind') IS NULL
   OR OBJECT_ID('grac_practice.sp_task_open','P') IS NULL
   OR COL_LENGTH('grac_practice.practice_task','source_type_code') IS NULL
   OR OBJECT_ID('grac_practice.task_type_master','U') IS NULL
   OR NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_practice_task_source_type')
BEGIN
    RAISERROR('ABORT (449): run 028, 196, 215 and 336-338 first.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. Task type
-- =====================================================================
MERGE grac_practice.task_type_master AS t
USING (VALUES (N'ScheduledObligation', N'Scheduled Obligation',
               N'Task for one due occurrence of a scheduled Execution / Assurance obligation',
               24, N'Medium', 1, 95))
   AS s(type_code, type_name, description, default_sla_hours, default_priority, is_system_only, display_order)
ON t.type_code = s.type_code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (type_code, type_name, description, default_sla_hours, default_priority, is_system_only, display_order, entered_by)
    VALUES (s.type_code, s.type_name, s.description, s.default_sla_hours, s.default_priority, s.is_system_only, s.display_order, N'seed-449');
PRINT CONCAT('449: task type inserted: ', @@ROWCOUNT);
GO

-- =====================================================================
-- 2. Task Centre source "Schedule" (additive; 438's list kept verbatim)
--
-- 438 (asset activities) is NOT required. The list below is 215's plus
-- 'Asset' (438) plus 'Schedule': allowing a value no row uses yet is
-- harmless, and it means a database that runs 438 AFTER 449 keeps both
-- (438 skips its own widening when 'Asset' is already allowed).
-- =====================================================================
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints
                WHERE name = 'ck_pm_practice_task_source_type'
                  AND definition LIKE '%Schedule''%')
BEGIN
    ALTER TABLE grac_practice.practice_task DROP CONSTRAINT ck_pm_practice_task_source_type;
    ALTER TABLE grac_practice.practice_task WITH NOCHECK
        ADD CONSTRAINT ck_pm_practice_task_source_type
            CHECK (source_type_code IS NULL
                OR source_type_code IN (N'Gap', N'Exception', N'Risk',
                                        N'RiskRegister',
                                        N'ContinuousAssurance', N'EventAssurance',
                                        N'Custom',
                                        N'Asset',
                                        N'Schedule'));                    -- NEW in 449
    PRINT '449: practice_task source vocabulary widened (Schedule).';
END
GO

-- =====================================================================
-- 3. Occurrence -> task ledger (the duplicate guard)
-- =====================================================================
IF OBJECT_ID('grac_practice.schedule_occurrence_task','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.schedule_occurrence_task (
        occurrence_task_id   BIGINT IDENTITY(1,1) NOT NULL
            CONSTRAINT pk_pm_sched_occ_task PRIMARY KEY,
        organization_id      BIGINT NOT NULL
            CONSTRAINT fk_pm_sched_occ_task_org REFERENCES grac_practice.organization(organization_id),
        schedule_rule_id     BIGINT NOT NULL
            CONSTRAINT fk_pm_sched_occ_task_rule REFERENCES grac_practice.assurance_schedule_rule(schedule_rule_id),
        occurrence_date      DATE   NOT NULL,
        practice_instance_id BIGINT NOT NULL,
        practice_instance_obligation_id BIGINT NULL,
        task_id              BIGINT NULL,
        task_error           NVARCHAR(1000) NULL,
        entered_by           NVARCHAR(100) NOT NULL,
        entered_dt           DATETIME2 NOT NULL CONSTRAINT df_pm_sched_occ_task_dt DEFAULT SYSUTCDATETIME(),
        updated_by           NVARCHAR(100) NULL,
        updated_dt           DATETIME2 NULL,
        CONSTRAINT uq_pm_sched_occ_task UNIQUE (schedule_rule_id, occurrence_date)
    );
    CREATE INDEX ix_pm_sched_occ_task_date ON grac_practice.schedule_occurrence_task (occurrence_date, task_id);
    PRINT '449: schedule_occurrence_task created.';
END
GO

-- =====================================================================
-- 4. Generator
-- =====================================================================
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
                       @descr    = CONCAT(N'Scheduled ', COALESCE(r.schedule_kind, N'Assurance'),
                                          N' obligation due ', @date_text, N'.', CHAR(13), CHAR(10),
                                          N'Practice instance: ', pi.instance_code, N' - ', pi.instance_name, CHAR(13), CHAR(10),
                                          N'Frequency: ', fm.frequency_name,
                                          CASE WHEN pio.responsibility IS NULL THEN N''
                                               ELSE CONCAT(CHAR(13), CHAR(10), N'Responsibility: ', pio.responsibility) END),
                       @ref      = CONCAT(N'Schedule rule ', x.schedule_rule_id, N' / ', CONVERT(NVARCHAR(10), x.occurrence_date, 23))
                  FROM grac_practice.schedule_occurrence_task x
                  JOIN grac_practice.assurance_schedule_rule r ON r.schedule_rule_id = x.schedule_rule_id
                  JOIN grac_practice.frequency_master fm ON fm.frequency_id = r.frequency_id
                  JOIN grac_practice.practice_instance pi ON pi.practice_instance_id = x.practice_instance_id
                  LEFT JOIN grac_practice.practice_instance_obligation pio
                         ON pio.practice_instance_obligation_id = x.practice_instance_obligation_id
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
PRINT '449: sp_schedule_obligation_tasks_generate ready.';
GO

-- =====================================================================
-- 5. sp_task_centre_source_counts -- 438's body + Schedule
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_task_centre_source_counts
    @organization_id BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    -- Result set 1 -- the filterable vocabulary, in dropdown order.
    ;WITH vocab(SourceTypeCode, DisplayOrder) AS (
        SELECT N'Gap',                 1 UNION ALL
        SELECT N'Exception',           2 UNION ALL
        SELECT N'Risk',                3 UNION ALL
        SELECT N'RiskRegister',        4 UNION ALL
        SELECT N'ContinuousAssurance', 5 UNION ALL
        SELECT N'EventAssurance',      6 UNION ALL
        SELECT N'Custom',              7 UNION ALL
        SELECT N'Asset',               8 UNION ALL                                     -- 438
        SELECT N'Schedule',            9                                               -- 449
    )
    SELECT v.SourceTypeCode,
           v.DisplayOrder,
           (SELECT COUNT_BIG(*)
              FROM grac_practice.practice_task t
             WHERE (@organization_id IS NULL OR t.organization_id = @organization_id)
               AND t.parent_task_id IS NULL
               AND t.source_type_code = v.SourceTypeCode) AS TaskCount
    FROM   vocab v
    ORDER  BY v.DisplayOrder;

    -- Result set 2 -- totals, so the dropdown can label "All sources"
    -- and the caller can see how many rows carry no source at all.
    SELECT
        (SELECT COUNT_BIG(*)
           FROM grac_practice.practice_task t
          WHERE (@organization_id IS NULL OR t.organization_id = @organization_id)
            AND t.parent_task_id IS NULL) AS TotalCount,
        (SELECT COUNT_BIG(*)
           FROM grac_practice.practice_task t
          WHERE (@organization_id IS NULL OR t.organization_id = @organization_id)
            AND t.parent_task_id IS NULL
            AND t.source_type_code IS NULL) AS UnsourcedCount;
END
GO
PRINT '449: sp_task_centre_source_counts re-issued.';
GO

-- =====================================================================
-- Verification
-- =====================================================================
SELECT '449-a task type ScheduledObligation' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM grac_practice.task_type_master WHERE type_code = N'ScheduledObligation')
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '449-b source vocabulary has Schedule',
       CASE WHEN EXISTS (SELECT 1 FROM sys.check_constraints
                          WHERE name = 'ck_pm_practice_task_source_type' AND definition LIKE '%Schedule''%'
                            AND definition LIKE '%Asset''%')
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '449-c schedule_occurrence_task exists',
       CASE WHEN OBJECT_ID('grac_practice.schedule_occurrence_task','U') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '449-d generator exists',
       CASE WHEN OBJECT_ID('grac_practice.sp_schedule_obligation_tasks_generate','P') IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '449-e source counts list Schedule',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_task_centre_source_counts')) LIKE '%N''Schedule''%'
            THEN 'PASS' ELSE 'FAIL' END;
GO
PRINT '449 complete. Today''s tasks: EXEC grac_practice.sp_schedule_obligation_tasks_generate;';
GO
SET NOEXEC OFF;
GO
