-- =====================================================================
-- 355 ROLLBACK -- retire/restore reason requirement
--
-- Puts sp_resolve_instance_retire and sp_resolve_instance_restore back
-- to exactly 222's and 287's shape (no @remark, no history write), and
-- drops practice_instance_status_history.
--
-- READ THIS BEFORE RUNNING IT
--   Every reason typed since 355 ran is in practice_instance_status_
--   history. Dropping the table below deletes that audit trail
--   permanently. The count at the bottom says how many rows that is on
--   this database before you run it.
--
--   The API tier binds @remark unconditionally once its own migration
--   has been applied (see 355's companion C# changes); if that code is
--   still deployed when this rollback runs, every retire/restore call
--   will fail with "@remark is not a parameter" until the API is rolled
--   back too. Roll back the API deploy first, or accept that window.
--
-- Re-runnable: yes.
-- =====================================================================
SET NOCOUNT ON;
GO

PRINT '=== 355 rollback: rows about to be lost ===';
IF OBJECT_ID('grac_practice.practice_instance_status_history','U') IS NOT NULL
    SELECT COUNT(*) AS StatusHistoryRowsToBeDeleted
    FROM   grac_practice.practice_instance_status_history;
GO

-- ---- sp_resolve_instance_retire, exactly as 222 left it --------------
CREATE OR ALTER PROCEDURE grac_practice.sp_resolve_instance_retire
    @practice_instance_id BIGINT,
    @caller_employee_id   BIGINT        = NULL,
    @is_admin             BIT           = 0,
    @actor                NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;

    IF @practice_instance_id IS NULL
        THROW 52680, 'sp_resolve_instance_retire: practice_instance_id is required.', 1;

    DECLARE @current_owner_id BIGINT, @current_status NVARCHAR(30);

    SELECT @current_owner_id = primary_owner_id,
           @current_status   = status
    FROM   grac_practice.practice_instance
    WHERE  practice_instance_id = @practice_instance_id;

    IF @current_status IS NULL
        THROW 52681, 'sp_resolve_instance_retire: instance not found.', 1;

    IF @is_admin = 0 AND ISNULL(@current_owner_id, -1) <> ISNULL(@caller_employee_id, -2)
        THROW 52682, 'sp_resolve_instance_retire: this practice instance belongs to another owner.', 1;

    IF @current_status <> N'Active'
        THROW 52683, 'sp_resolve_instance_retire: this practice instance is already retired.', 1;

    DECLARE @inactive_record_status_id INT = (
        SELECT TOP 1 record_status_id
        FROM   grac_practice.record_status_master
        WHERE  status_code = N'Inactive' OR status_name = N'Inactive'
        ORDER  BY record_status_id
    );

    UPDATE grac_practice.practice_instance
       SET status           = N'Inactive',
           record_status_id = COALESCE(@inactive_record_status_id, record_status_id),
           updated_by       = @actor,
           updated_dt       = SYSUTCDATETIME()
     WHERE practice_instance_id = @practice_instance_id;

    SELECT CAST(1 AS BIT) AS Success,
           N'Practice instance retired.' AS Message,
           pi.status AS Status
    FROM   grac_practice.practice_instance pi
    WHERE  pi.practice_instance_id = @practice_instance_id;
END
GO

-- ---- sp_resolve_instance_restore, exactly as 287 left it -------------
CREATE OR ALTER PROCEDURE grac_practice.sp_resolve_instance_restore
    @practice_instance_id BIGINT,
    @caller_employee_id   BIGINT        = NULL,
    @is_admin             BIT           = 0,
    @actor                NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;

    IF @practice_instance_id IS NULL
        THROW 52810, 'sp_resolve_instance_restore: practice_instance_id is required.', 1;

    DECLARE @current_owner_id BIGINT, @current_status NVARCHAR(30), @practice_id BIGINT;

    SELECT @current_owner_id = primary_owner_id,
           @current_status   = status,
           @practice_id      = practice_id
    FROM   grac_practice.practice_instance
    WHERE  practice_instance_id = @practice_instance_id;

    IF @current_status IS NULL
        THROW 52811, 'sp_resolve_instance_restore: instance not found.', 1;

    IF @is_admin = 0 AND ISNULL(@current_owner_id, -1) <> ISNULL(@caller_employee_id, -2)
        THROW 52812, 'sp_resolve_instance_restore: this practice instance belongs to another owner.', 1;

    IF @current_status = N'Active'
        THROW 52813, 'sp_resolve_instance_restore: this practice instance is already active.', 1;

    IF EXISTS (SELECT 1 FROM grac_practice.practice
                WHERE practice_id = @practice_id AND status <> N'Active')
        THROW 52814, 'sp_resolve_instance_restore: the parent practice is not active. Restore the practice first.', 1;

    DECLARE @active_record_status_id INT = (
        SELECT TOP 1 record_status_id
        FROM   grac_practice.record_status_master
        WHERE  status_code = N'Active' OR status_name = N'Active'
        ORDER  BY record_status_id
    );

    UPDATE grac_practice.practice_instance
       SET status           = N'Active',
           record_status_id = COALESCE(@active_record_status_id, record_status_id),
           updated_by       = @actor,
           updated_dt       = SYSUTCDATETIME()
     WHERE practice_instance_id = @practice_instance_id;

    SELECT CAST(1 AS BIT) AS Success,
           N'Practice instance restored.' AS Message,
           pi.status AS Status
    FROM   grac_practice.practice_instance pi
    WHERE  pi.practice_instance_id = @practice_instance_id;
END
GO

IF OBJECT_ID('grac_practice.practice_instance_status_history','U') IS NOT NULL
    DROP TABLE grac_practice.practice_instance_status_history;
GO

-- =====================================================================
-- Verification
-- =====================================================================
SELECT '355 rollback: retire has no @remark' AS Check_,
       CASE WHEN NOT EXISTS (SELECT 1 FROM sys.parameters
                              WHERE object_id = OBJECT_ID('grac_practice.sp_resolve_instance_retire')
                                AND name = '@remark')
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '355 rollback: restore has no @remark',
       CASE WHEN NOT EXISTS (SELECT 1 FROM sys.parameters
                              WHERE object_id = OBJECT_ID('grac_practice.sp_resolve_instance_restore')
                                AND name = '@remark')
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '355 rollback: history table dropped',
       CASE WHEN OBJECT_ID('grac_practice.practice_instance_status_history','U') IS NULL
            THEN 'PASS' ELSE 'FAIL' END;

PRINT '355 rollback complete.';
PRINT '     Retire and Restore no longer ask for or record a reason.';
PRINT '     Remember: the API tier must also be rolled back to its';
PRINT '     pre-355 build, or it will still try to send @remark.';
GO
