# Scheduled obligation tasks (migration 449)

**Request (2026-10-06):** obligations scheduled on Operationalize showed on
the Assurance Calendar but never produced a task. A task is now raised for
each occurrence **on its due date** (not ahead of it).

## How it works

1. Operationalize save -> `sp_pm_sync_instance_schedule_rules` (338) keeps
   one `assurance_schedule_rule` per schedulable Execution / Assurance
   obligation (unchanged).
2. `TaskNotificationWorker` runs `sp_schedule_obligation_tasks_generate`
   every `ScheduledObligationTasksIntervalMinutes` (default 60).
3. The procedure works out which occurrences fall on **today (UTC)** -- the
   same arithmetic as the calendar (`QueryCalendarEventsAsync`): anchor date
   stepped by Day n / Week n*7 / Month n / Year n up to `end_date`, then the
   calendar overrides (Skipped / Moved remove the original date, Moved and
   Added add theirs).
4. Each (rule, date) is claimed once in `schedule_occurrence_task`
   (UNIQUE) and a task is opened with `sp_task_open`:

| Task field | Value |
|---|---|
| Type | `ScheduledObligation` ("Scheduled Obligation", system-only) |
| Source | `Schedule` ("Scheduled obligation" on Task Board), record = occurrence id |
| Title | obligation name (or instance name) + " - due dd Mon yyyy" |
| Owner | the instance's primary owner when an active employee; otherwise the `sp_task_owner_resolve` ladder |
| Start / target | due date 00:00 / 23:59:59 UTC |
| Linked / related | practice instance and its practice |

Only Active rules, Active practice instances and Active adopted obligations
are considered. A task that fails to open leaves `task_error` on the row and
is retried on the next pass the same day. An application lock stops two API
instances raising the same task.

## Configuration (`appsettings.json`, section `TaskNotification`)

| Key | Default | Meaning |
|---|---|---|
| `ScheduledObligationTasksEnabled` | `true` | run the pass from the worker |
| `ScheduledObligationTasksIntervalMinutes` | `60` | minutes between passes (5-1440) |

With the pass disabled, schedule it in SQL Agent:
`EXEC grac_practice.sp_schedule_obligation_tasks_generate;`

## Not done / by design

- **No back-fill.** A day on which the API was down is not raised later
  automatically. To raise a specific day on purpose:
  `EXEC grac_practice.sp_schedule_obligation_tasks_generate @run_date = '2026-10-05';`
- "Today" is the UTC date, the same as the calendar's Past / Upcoming and
  the asset scheduler (for IST, the day's tasks appear from 05:30).
- Task Board: new source filter option; Task View shows the source as
  plain text (no full view to link to). Calendar: the occurrence's task is
  shown in the side panel once raised.

## API

No new endpoint. `ITaskNotificationService.GenerateScheduledObligationTasksAsync
(organizationId, runDate)` returns `ScheduledObligationTaskRunResult`
(`RunDate`, `Result` = OK / SKIPPED / NOT_INSTALLED, `TasksCreated`,
`ErrorCount`). The calendar events payload (`assurance-calendar-events`)
now carries `LinkedTaskId / LinkedTaskNumber / LinkedTaskStatus /
LinkedTaskDeepLink` on schedule-rule occurrences that have a task.

## Rollback

`449_scheduled_obligation_tasks_rollback.sql` (turn the worker pass off
first). Tasks already raised remain as ordinary Task Centre tasks.
