-- =====================================================================
-- 459_scheduled_task_obligation_description_rollback.sql
-- Restores sp_schedule_obligation_tasks_generate to its 449 body (the
-- generated summary as the task description). Descriptions already
-- written to tasks are left as they are. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
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
PRINT '459 rollback complete.';
GO
