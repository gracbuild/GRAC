-- =====================================================================
-- 474_repository_change_detect_agent_job_rollback.sql
-- Removes the SQL Agent job (and its schedule) created by 474 for THIS
-- database. Run it in the same database 474 was run in.
-- Afterwards detection runs only if the API worker is enabled
-- ("RepositoryChangeDetect": { "Enabled": true }, the default).
-- ASCII-only. Safe to re-run.
-- =====================================================================
SET NOCOUNT ON;
DECLARE @job_name SYSNAME = N'GRAC - Repository Change Detect (' + DB_NAME() + N')';
IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = @job_name)
BEGIN
    EXEC msdb.dbo.sp_delete_job @job_name = @job_name, @delete_unused_schedule = 1;
    PRINT 'OK (474 rollback): removed Agent job "' + @job_name + '".';
END
ELSE
    PRINT 'OK (474 rollback): no Agent job "' + @job_name + '" -- nothing to do.';
GO
