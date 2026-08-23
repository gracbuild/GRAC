-- =====================================================================
-- 128 Obligation-based event scoping procedures -- ROLLBACK
--
-- Drops the four new procedures and restores the two lifecycle wrappers
-- to their 124 bodies (checklist path only).
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.sp_event_obligation_raise','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_event_obligation_raise;
GO
IF OBJECT_ID('grac_practice.sp_event_obligation_coverage_list','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_event_obligation_coverage_list;
GO
IF OBJECT_ID('grac_practice.sp_event_obligation_applicability_save','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_event_obligation_applicability_save;
GO
IF OBJECT_ID('grac_practice.sp_event_obligation_mapping_list','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_event_obligation_mapping_list;
GO

-- ---------------------------------------------------------------------
-- Restore the 124 wrappers (checklist path only).
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE grac_practice.sp_event_raise_people_lifecycle
    @organization_id   BIGINT,
    @employee_id       BIGINT,
    @lifecycle_action  NVARCHAR(20),
    @effective_date    DATE          = NULL,
    @event_code        NVARCHAR(60)  = NULL,
    @trigger_source    NVARCHAR(60)  = N'Manual',
    @actor_employee_id BIGINT        = NULL,
    @out_raised_count  INT           OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @lifecycle_action NOT IN (N'ONBOARD', N'OFFBOARD')
        THROW 67230, 'sp_event_raise_people_lifecycle: lifecycle_action must be ONBOARD or OFFBOARD.', 1;

    SET @effective_date = ISNULL(@effective_date, CAST(SYSUTCDATETIME() AS DATE));
    DECLARE @actor NVARCHAR(100) = COALESCE(CAST(@actor_employee_id AS NVARCHAR(100)), 'api');

    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee
                    WHERE employee_id = @employee_id AND organization_id = @organization_id)
        THROW 67231, 'sp_event_raise_people_lifecycle: employee not found in this organization.', 1;

    IF @event_code IS NULL
        SET @event_code = CASE @lifecycle_action
                               WHEN N'ONBOARD' THEN N'PEOPLE_ONBOARDING'
                               ELSE N'PEOPLE_OFFBOARDING' END;

    IF @lifecycle_action = N'ONBOARD'
        UPDATE grac_practice.organization_employee
           SET onboarded_dt = ISNULL(onboarded_dt, @effective_date),
               status = N'Active', updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE employee_id = @employee_id AND organization_id = @organization_id;
    ELSE
        UPDATE grac_practice.organization_employee
           SET offboarded_dt = @effective_date,
               status = N'Inactive', updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE employee_id = @employee_id AND organization_id = @organization_id;

    EXEC grac_practice.sp_event_instance_raise_scoped
         @organization_id = @organization_id, @event_code = @event_code,
         @subject_entity = N'EMPLOYEE', @subject_record_id = @employee_id,
         @effective_date = @effective_date, @trigger_source = @trigger_source,
         @actor_employee_id = @actor_employee_id,
         @out_raised_count = @out_raised_count OUTPUT;
END;
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_event_raise_asset_lifecycle
    @organization_id   BIGINT,
    @asset_id          BIGINT,
    @lifecycle_action  NVARCHAR(20),
    @effective_date    DATE          = NULL,
    @event_code        NVARCHAR(60)  = NULL,
    @trigger_source    NVARCHAR(60)  = N'Manual',
    @actor_employee_id BIGINT        = NULL,
    @out_raised_count  INT           OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @lifecycle_action NOT IN (N'COMMISSION', N'DECOMMISSION')
        THROW 67240, 'sp_event_raise_asset_lifecycle: lifecycle_action must be COMMISSION or DECOMMISSION.', 1;

    SET @effective_date = ISNULL(@effective_date, CAST(SYSUTCDATETIME() AS DATE));
    DECLARE @actor NVARCHAR(100) = COALESCE(CAST(@actor_employee_id AS NVARCHAR(100)), 'api');

    DECLARE @current NVARCHAR(30);
    SELECT @current = lifecycle_status
    FROM   grac_practice.organization_dependency_asset
    WHERE  asset_id = @asset_id AND organization_id = @organization_id;
    IF @@ROWCOUNT = 0
        THROW 67241, 'sp_event_raise_asset_lifecycle: asset not found in this organization.', 1;
    IF @lifecycle_action = N'DECOMMISSION' AND @current = N'Decommissioned'
        THROW 67242, 'sp_event_raise_asset_lifecycle: asset is already decommissioned.', 1;
    IF @lifecycle_action = N'COMMISSION' AND @current = N'Commissioned'
        THROW 67243, 'sp_event_raise_asset_lifecycle: asset is already commissioned.', 1;

    IF @event_code IS NULL
        SET @event_code = CASE @lifecycle_action
                               WHEN N'COMMISSION' THEN N'ASSET_COMMISSIONING'
                               ELSE N'ASSET_DECOMMISSIONING' END;

    IF @lifecycle_action = N'COMMISSION'
        UPDATE grac_practice.organization_dependency_asset
           SET lifecycle_status = N'Commissioned', commissioned_dt = @effective_date,
               decommissioned_dt = NULL, updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE asset_id = @asset_id AND organization_id = @organization_id;
    ELSE
        UPDATE grac_practice.organization_dependency_asset
           SET lifecycle_status = N'Decommissioned', decommissioned_dt = @effective_date,
               updated_by = @actor, updated_dt = SYSUTCDATETIME()
         WHERE asset_id = @asset_id AND organization_id = @organization_id;

    EXEC grac_practice.sp_event_instance_raise_scoped
         @organization_id = @organization_id, @event_code = @event_code,
         @subject_entity = N'ASSET', @subject_record_id = @asset_id,
         @effective_date = @effective_date, @trigger_source = @trigger_source,
         @actor_employee_id = @actor_employee_id,
         @out_raised_count = @out_raised_count OUTPUT;
END;
GO

SELECT '128 procedures dropped' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.sp_event_obligation_mapping_list','P') IS NULL
             AND OBJECT_ID('grac_practice.sp_event_obligation_raise','P') IS NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;

PRINT '128 Obligation-based event scoping procedures rolled back.';
GO
