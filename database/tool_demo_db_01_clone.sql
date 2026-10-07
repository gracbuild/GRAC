-- =====================================================================
-- tool_demo_db_01_clone.sql  --  step 1 of 2: copy UAT to the demo DB
--
-- REQUEST (2026-10-06)
--   A demo database grac_new_demo built from UAT (grac_newphase_uat):
--   every schema object, all of GRAC_New and every master table, but
--   organization data for MSP (organization_id 1) and SD (9) only.
--
-- WHY A BACKUP/RESTORE, NOT A HAND-WRITTEN CREATE SCRIPT
--   The schema is 400+ migrations deep (tables, procedures, views,
--   functions, triggers, the row-level security policy of 415, GRAC_New).
--   A restore copies all of it exactly as UAT has it; step 2
--   (tool_demo_db_02_keep_orgs.sql) then removes the other organizations'
--   rows inside the copy. UAT itself is only READ (a COPY_ONLY backup,
--   which does not disturb UAT's own backup chain).
--
-- RUN
--   In SSMS, connected to the UAT SQL Server, as a login with BACKUP
--   DATABASE on UAT and CREATE DATABASE (sysadmin or dbcreator +
--   db_backupoperator). Run the whole script (one batch).
--   grac_new_demo must NOT exist yet -- the script stops if it does.
--
-- SETTINGS BELOW
--   @BackupFile  NULL = <server default backup folder>\grac_newphase_uat_demo_copy.bak
--                The SQL Server SERVICE account must be able to write there.
--   @DataPath / @LogPath  NULL = the server's default data / log folders.
--
-- AFTER THIS: run tool_demo_db_02_keep_orgs.sql against grac_new_demo.
-- ASCII-only.
-- =====================================================================
USE master;
SET NOCOUNT ON;

DECLARE @Source     SYSNAME        = N'grac_newphase_uat';
DECLARE @Target     SYSNAME        = N'grac_demo';
DECLARE @BackupFile NVARCHAR(4000) = NULL;
DECLARE @DataPath   NVARCHAR(4000) = NULL;
DECLARE @LogPath    NVARCHAR(4000) = NULL;

IF DB_ID(@Source) IS NULL
BEGIN
    RAISERROR('Source database %s not found on this server.', 16, 1, @Source);
    RETURN;
END
IF DB_ID(@Target) IS NOT NULL
BEGIN
    RAISERROR('Target database %s already exists. Drop or rename it first -- this script never overwrites a database.', 16, 1, @Target);
    RETURN;
END

SET @DataPath = COALESCE(@DataPath, CONVERT(NVARCHAR(4000), SERVERPROPERTY('InstanceDefaultDataPath')));
SET @LogPath  = COALESCE(@LogPath,  CONVERT(NVARCHAR(4000), SERVERPROPERTY('InstanceDefaultLogPath')));
IF @BackupFile IS NULL
    SET @BackupFile = CONCAT(CONVERT(NVARCHAR(4000), SERVERPROPERTY('InstanceDefaultBackupPath')),
                             N'\', @Source, N'_demo_copy.bak');
IF @DataPath IS NULL OR @LogPath IS NULL OR @BackupFile IS NULL OR @BackupFile = N'\' + @Source + N'_demo_copy.bak'
BEGIN
    RAISERROR('Could not resolve the default folders (older SQL Server). Set @BackupFile, @DataPath and @LogPath at the top and run again.', 16, 1);
    RETURN;
END
IF RIGHT(@DataPath, 1) <> N'\' SET @DataPath += N'\';
IF RIGHT(@LogPath, 1)  <> N'\' SET @LogPath  += N'\';

PRINT CONCAT('Backup file : ', @BackupFile);
PRINT CONCAT('Data folder : ', @DataPath);
PRINT CONCAT('Log folder  : ', @LogPath);

-- 1. COPY_ONLY backup of UAT (UAT keeps running; its backup chain is untouched).
DECLARE @sql NVARCHAR(MAX) = CONCAT(
    N'BACKUP DATABASE ', QUOTENAME(@Source), N' TO DISK = N''', REPLACE(@BackupFile, N'''', N''''''), N'''',
    N' WITH COPY_ONLY, INIT, CHECKSUM, STATS = 10;');
PRINT @sql;
EXEC (@sql);

-- 2. Restore as the demo database. One MOVE per file of the source,
--    taken from sys.master_files (logical names are the source's own).
DECLARE @move NVARCHAR(MAX) = N'';
SELECT @move += CONCAT(N', MOVE N''', REPLACE(mf.name, N'''', N''''''), N''' TO N''',
                       CASE WHEN mf.type_desc = N'LOG' THEN @LogPath ELSE @DataPath END,
                       @Target, N'_', mf.file_id,
                       CASE mf.type_desc WHEN N'LOG' THEN N'.ldf' WHEN N'ROWS' THEN CASE WHEN mf.file_id = 1 THEN N'.mdf' ELSE N'.ndf' END ELSE N'' END,
                       N'''')
  FROM sys.master_files mf
 WHERE mf.database_id = DB_ID(@Source)
 ORDER BY mf.file_id;

SET @sql = CONCAT(N'RESTORE DATABASE ', QUOTENAME(@Target), N' FROM DISK = N''', REPLACE(@BackupFile, N'''', N''''''), N'''',
                  N' WITH RECOVERY, CHECKSUM, STATS = 10', @move, N';');
PRINT @sql;
EXEC (@sql);

-- 3. Open for use (a restore keeps the source's options; make sure).
SET @sql = CONCAT(N'ALTER DATABASE ', QUOTENAME(@Target), N' SET MULTI_USER;');
EXEC (@sql);

SELECT name AS DatabaseName, state_desc, recovery_model_desc, create_date
  FROM sys.databases WHERE name = @Target;
PRINT 'Step 1 complete. Next: run tool_demo_db_02_keep_orgs.sql in grac_new_demo.';
PRINT 'The .bak file above can be deleted once step 2 has been checked.';
