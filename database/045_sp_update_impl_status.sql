-- =====================================================================
-- 045 sp_practice_instance_update_implementation_status
--
-- Dedicated status-change procedure for the "Update Implementation
-- Status" popup. Captures remarks + effective date + actor, writes
-- practice_audit_trace with before/after JSON.
--
-- Params:
--   @practice_instance_id BIGINT
--   @new_status_code      NVARCHAR(60)  — must be an active master row
--   @remarks              NVARCHAR(2000) NULL
--   @effective_date       DATETIME2 NULL — defaults to SYSUTCDATETIME()
--   @actor_employee_id    BIGINT NULL
--
-- Errors:
--   54501 instance not found
--   54502 unknown / inactive status code
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.practice_instance','U') IS NULL
   OR OBJECT_ID('grac_practice.implementation_status_master','U') IS NULL
   OR OBJECT_ID('grac_practice.practice_audit_trace','U') IS NULL
BEGIN
    PRINT 'ABORT (045-proc): required tables missing.';
    RAISERROR('045-proc prereqs missing', 16, 1);
    SET NOEXEC ON;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_practice_instance_update_implementation_status
    @practice_instance_id BIGINT,
    @new_status_code      NVARCHAR(60),
    @remarks              NVARCHAR(2000) = NULL,
    @effective_date       DATETIME2      = NULL,
    @actor_employee_id    BIGINT         = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @practice_instance_id IS NULL
        THROW 54503, 'sp_practice_instance_update_implementation_status: @practice_instance_id required.', 1;
    IF @new_status_code IS NULL OR LTRIM(RTRIM(@new_status_code)) = N''
        THROW 54504, 'sp_practice_instance_update_implementation_status: @new_status_code required.', 1;

    IF @effective_date IS NULL SET @effective_date = SYSUTCDATETIME();

    DECLARE @old_status_code NVARCHAR(60),
            @old_status_id   INT,
            @instance_code   NVARCHAR(100);

    SELECT @old_status_code = COALESCE(ims.status_code, pi.implementation_status),
           @old_status_id   = pi.implementation_status_id,
           @instance_code   = pi.instance_code
    FROM grac_practice.practice_instance pi
    LEFT JOIN grac_practice.implementation_status_master ims ON ims.implementation_status_id = pi.implementation_status_id
    WHERE pi.practice_instance_id = @practice_instance_id;

    IF @instance_code IS NULL
    BEGIN
        DECLARE @msg NVARCHAR(200) = CONCAT('Practice Instance ', CAST(@practice_instance_id AS NVARCHAR(30)), ' not found.');
        THROW 54501, @msg, 1;
    END

    DECLARE @new_status_id INT;
    SELECT @new_status_id = implementation_status_id
    FROM grac_practice.implementation_status_master
    WHERE status_code = @new_status_code
      AND is_active = 1;

    IF @new_status_id IS NULL
    BEGIN
        DECLARE @msg2 NVARCHAR(200) = CONCAT('Unknown or inactive status_code: ''', @new_status_code, '''.');
        THROW 54502, @msg2, 1;
    END

    DECLARE @actor_label NVARCHAR(100) =
        CASE WHEN @actor_employee_id IS NOT NULL
             THEN CONCAT('emp:', CAST(@actor_employee_id AS NVARCHAR(30)))
             ELSE N'system' END;

    BEGIN TRAN;

    UPDATE grac_practice.practice_instance
       SET implementation_status    = @new_status_code,
           implementation_status_id = @new_status_id,
           updated_by               = @actor_label,
           updated_dt               = SYSUTCDATETIME()
     WHERE practice_instance_id = @practice_instance_id;

    -- Audit trail
    DECLARE @before_json NVARCHAR(MAX) = (SELECT @old_status_code AS status_code, @old_status_id AS status_id FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
    DECLARE @after_json  NVARCHAR(MAX) = (SELECT @new_status_code AS status_code,
                                                 @new_status_id  AS status_id,
                                                 @remarks        AS remarks,
                                                 @effective_date AS effective_date,
                                                 @actor_employee_id AS actor_employee_id
                                          FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    INSERT INTO grac_practice.practice_audit_trace
        (entity_type, entity_id, action_type, before_json, after_json,
         status, entered_by, entered_dt)
    VALUES
        (N'PracticeInstance', @practice_instance_id, N'IMPL_STATUS_CHANGE',
         @before_json, @after_json,
         N'Active', @actor_label, SYSUTCDATETIME());

    COMMIT TRAN;

    -- Return the new state so the API can echo it back to the UI.
    SELECT pi.practice_instance_id  AS PracticeInstanceId,
           pi.implementation_status AS ImplementationStatus,
           pi.implementation_status_id AS ImplementationStatusId
    FROM grac_practice.practice_instance pi
    WHERE pi.practice_instance_id = @practice_instance_id;
END;
GO

PRINT '045 sp_practice_instance_update_implementation_status installed.';
GO

SET NOEXEC OFF;
GO
