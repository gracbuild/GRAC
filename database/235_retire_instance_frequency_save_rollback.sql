-- =====================================================================
-- 235 Retire the instance-level "Save frequency" flow -- ROLLBACK
--
-- READ THIS BEFORE RUNNING IT
-- ---------------------------
-- 235 dropped a procedure that no live code path calls. Rolling it back
-- puts the procedure body back but does NOT bring the UI or API surface
-- back with it -- the controller endpoint, the service method, the
-- record, and the "Save frequency" box are all gone from the app tier.
--
-- So this rollback is only useful in one situation: something outside
-- this codebase (a report, a scheduled job, an integration script) still
-- calls sp_resolve_instance_frequency_save and needs it to keep
-- resolving. If nothing calls it, running this rollback creates dead
-- code you now have to maintain.
--
-- WHAT IT DOES
-- ------------
-- Re-creates sp_resolve_instance_frequency_save in exactly the shape
-- migration 145 left it -- same parameters, same body. Idempotent
-- (CREATE OR ALTER).
--
-- ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    PRINT 'ABORT (235 rollback): schema grac_practice missing.';
    SET NOEXEC ON;
END
GO

IF OBJECT_ID('grac_practice.practice_instance','U') IS NULL
BEGIN
    PRINT 'ABORT (235 rollback): practice_instance missing (run 001 first).';
    SET NOEXEC ON;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_resolve_instance_frequency_save
    @practice_instance_id   BIGINT,
    @execution_frequency_id INT    = NULL,
    @assurance_frequency_id INT    = NULL,
    @caller_employee_id     BIGINT = NULL,
    @is_admin               BIT    = 0,
    @actor                  NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;

    IF @practice_instance_id IS NULL
        THROW 52660, 'sp_resolve_instance_frequency_save: practice_instance_id is required.', 1;

    IF NOT EXISTS (SELECT 1 FROM grac_practice.practice_instance
                    WHERE practice_instance_id = @practice_instance_id)
        THROW 52661, 'sp_resolve_instance_frequency_save: instance not found.', 1;

    IF @is_admin = 0
       AND NOT EXISTS (SELECT 1 FROM grac_practice.practice_instance
                        WHERE practice_instance_id = @practice_instance_id
                          AND primary_owner_id     = @caller_employee_id)
        THROW 52662, 'sp_resolve_instance_frequency_save: this practice instance belongs to another owner.', 1;

    IF (@execution_frequency_id IS NOT NULL
        AND NOT EXISTS (SELECT 1 FROM grac_practice.frequency_master
                         WHERE frequency_id = @execution_frequency_id AND is_active = 1))
       OR (@assurance_frequency_id IS NOT NULL
        AND NOT EXISTS (SELECT 1 FROM grac_practice.frequency_master
                         WHERE frequency_id = @assurance_frequency_id AND is_active = 1))
        THROW 52663, 'sp_resolve_instance_frequency_save: that frequency does not exist.', 1;

    DECLARE @exec_name NVARCHAR(120) = (
        SELECT frequency_name FROM grac_practice.frequency_master
        WHERE frequency_id = @execution_frequency_id);

    UPDATE grac_practice.practice_instance
       SET execution_frequency_id = @execution_frequency_id,
           assurance_frequency_id = @assurance_frequency_id,
           frequency_id           = @execution_frequency_id,
           frequency_type         = COALESCE(@exec_name, frequency_type),
           updated_by             = @actor,
           updated_dt             = SYSUTCDATETIME()
     WHERE practice_instance_id = @practice_instance_id;

    SELECT CAST(1 AS BIT) AS Success,
           N'Frequency saved.' AS Message,
           ef.frequency_name AS ExecutionFrequency,
           af.frequency_name AS AssuranceFrequency
    FROM   grac_practice.practice_instance pi
    LEFT   JOIN grac_practice.frequency_master ef ON ef.frequency_id = pi.execution_frequency_id
    LEFT   JOIN grac_practice.frequency_master af ON af.frequency_id = pi.assurance_frequency_id
    WHERE  pi.practice_instance_id = @practice_instance_id;
END
GO

PRINT '=== 235 rollback verification ===';
SELECT 'save procedure restored' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.sp_resolve_instance_frequency_save','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;

PRINT '';
PRINT '235 rollback complete.';
GO

SET NOEXEC OFF;
GO
