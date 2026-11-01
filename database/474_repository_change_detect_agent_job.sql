-- =====================================================================
-- 474_repository_change_detect_agent_job.sql
--
-- REQUEST (2026-10-18)
-- --------------------
-- A database script for the scheduled task that brings repository
-- changes into Repository Updates (organization_repository_change).
--
-- WHAT IT DOES
-- ------------
-- Creates (or re-creates) one SQL Server Agent job that runs
--     grac_practice.sp_repository_change_detect
-- in THIS database once a day. That procedure (395) compares every
-- organization's copy of its subscribed releases with grac_new, records
-- each difference as a Pending change for the release owner / an
-- organization admin, and raises the Home notifications. Nothing is
-- applied: changes still wait for approval on Repository Updates.
--
-- WORKER VS AGENT -- PICK ONE
-- ---------------------------
-- The API already runs the same procedure on a timer
-- (RepositoryChangeDetectWorker, default once a day, first pass 5 minutes
-- after start-up). When this Agent job is used, turn the worker off in the
-- API's appsettings.json and restart the API:
--     "RepositoryChangeDetect": { "Enabled": false }
-- Running both is harmless -- detection is idempotent, a difference already
-- Pending / Approved / Rejected is never raised twice -- but it is wasted
-- work.
--
-- BEFORE RUNNING
-- --------------
--   * Run it in the Practice Management database (USE <db>; first). The job
--     step targets DB_NAME() at the time this script runs.
--   * Needs SQL Server Agent running, and a login allowed to create Agent
--     jobs (sysadmin or SQLAgentOperatorRole in msdb). The job is owned by
--     the login that runs this script.
--   * Adjust @run_time (HHMMSS, server local time) below if 02:00 does not
--     suit.
--
-- RUN NOW, WITHOUT WAITING FOR THE SCHEDULE
--     EXEC msdb.dbo.sp_start_job @job_name = N'GRAC - Repository Change Detect (<db>)';
-- or directly in this database:
--     EXEC grac_practice.sp_repository_change_detect;
--
-- SAFE TO RE-RUN (drops and re-creates the job). Requires 395.
-- Rollback: 474_repository_change_detect_agent_job_rollback.sql
-- ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.sp_repository_change_detect','P') IS NULL
BEGIN
    PRINT 'ABORT (474): grac_practice.sp_repository_change_detect not found -- run 395 first, in this database.';
    SET NOEXEC ON;
END
GO

DECLARE @db_name       SYSNAME       = DB_NAME();
DECLARE @job_name      SYSNAME       = N'GRAC - Repository Change Detect (' + DB_NAME() + N')';
DECLARE @schedule_name SYSNAME       = N'GRAC - Repository Change Detect daily (' + DB_NAME() + N')';
DECLARE @run_time      INT           = 20000;   -- HHMMSS: 02:00:00 server local time
DECLARE @command       NVARCHAR(MAX) = N'
DECLARE @raised INT, @notified INT;
EXEC grac_practice.sp_repository_change_detect
     @actor           = N''sql-agent'',
     @raised_count    = @raised OUTPUT,
     @notified_count  = @notified OUTPUT,
     @suppress_result = 1;
PRINT CONCAT(''Repository change detect: raised='', @raised, '' notified='', @notified);';
DECLARE @job_id UNIQUEIDENTIFIER;

-- Re-run: replace the job (and its schedule) rather than adding a second one.
IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = @job_name)
    EXEC msdb.dbo.sp_delete_job @job_name = @job_name, @delete_unused_schedule = 1;

EXEC msdb.dbo.sp_add_job
     @job_name     = @job_name,
     @enabled      = 1,
     @description  = N'Detects grac_new repository changes for every organization subscription and records them as Pending on Repository Updates (grac_practice.sp_repository_change_detect, migration 395). Created by 474.',
     @category_name = N'[Uncategorized (Local)]',
     @job_id       = @job_id OUTPUT;

EXEC msdb.dbo.sp_add_jobstep
     @job_id            = @job_id,
     @step_name         = N'Run sp_repository_change_detect',
     @subsystem         = N'TSQL',
     @database_name     = @db_name,
     @command           = @command,
     @on_success_action = 1,   -- quit reporting success
     @on_fail_action    = 2,   -- quit reporting failure (shows in job history)
     @retry_attempts    = 1,
     @retry_interval    = 15;  -- minutes

EXEC msdb.dbo.sp_add_schedule
     @schedule_name     = @schedule_name,
     @enabled           = 1,
     @freq_type         = 4,   -- daily
     @freq_interval     = 1,   -- every day
     @active_start_time = @run_time;

EXEC msdb.dbo.sp_attach_schedule
     @job_id        = @job_id,
     @schedule_name = @schedule_name;

EXEC msdb.dbo.sp_add_jobserver
     @job_id      = @job_id,
     @server_name = N'(local)';

PRINT 'OK (474): Agent job "' + @job_name + '" runs grac_practice.sp_repository_change_detect daily in [' + @db_name + ']. Set RepositoryChangeDetect:Enabled=false in the API if the worker should stop.';
GO
SET NOEXEC OFF;
GO
