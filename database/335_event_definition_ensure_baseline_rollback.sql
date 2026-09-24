-- =====================================================================
-- 335 ROLLBACK -- restore 128's lifecycle wrappers, drop the ensure
--
-- Restores sp_event_raise_people_lifecycle and sp_event_raise_asset_lifecycle
-- to migration 128's text, character for character, and drops
-- sp_event_definition_ensure_baseline.
--
-- AFTER THIS, ERROR 67223 COMES BACK for any organization that has no
-- event_definition row for the code being raised.
--
-- WHAT IS NOT UNDONE, AND WHY
-- ---------------------------
-- The event_definition and entity_type_master rows 335 created are LEFT
-- IN PLACE. They are the same four events migration 126 seeds for every
-- organization, they are the contract the restored wrappers below resolve
-- against, and deleting them would break organizations that are now
-- raising events successfully. If a specific organization should not
-- have one, deactivate it on the Events screen rather than deleting it
-- here -- the wrappers read status, so that is sufficient.
--
-- Rows created by 335 are identifiable by entered_by in
-- ('ensure-335', 'seed-335') if they ever need to be found.
--
-- SAFE TO RE-RUN.
-- ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.sp_event_raise_people_lifecycle','P') IS NULL
   OR OBJECT_ID('grac_practice.sp_event_raise_asset_lifecycle','P') IS NULL
BEGIN
    PRINT 'ABORT (335 rollback): the lifecycle wrappers are missing -- nothing to restore onto. Run 124 and 128.';
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 128's sp_event_raise_people_lifecycle, verbatim.
-- =====================================================================
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

    DECLARE @checklist_count INT = 0, @obligation_count INT = 0;

    EXEC grac_practice.sp_event_instance_raise_scoped
         @organization_id = @organization_id, @event_code = @event_code,
         @subject_entity = N'EMPLOYEE', @subject_record_id = @employee_id,
         @effective_date = @effective_date, @trigger_source = @trigger_source,
         @actor_employee_id = @actor_employee_id,
         @out_raised_count = @checklist_count OUTPUT;

    -- The obligation event type code mirrors the 066 event code, so the same
    -- string resolves in both taxonomies. If GRAC-ADMIN uses a different
    -- code, pass @event_code explicitly.
    IF EXISTS (SELECT 1 FROM GRAC_New.event_type_master
                WHERE event_code = @event_code AND status = N'Active')
        EXEC grac_practice.sp_event_obligation_raise
             @organization_id = @organization_id, @event_type_code = @event_code,
             @subject_entity = N'EMPLOYEE', @subject_record_id = @employee_id,
             @effective_date = @effective_date, @trigger_source = @trigger_source,
             @actor_employee_id = @actor_employee_id,
             @out_raised_count = @obligation_count OUTPUT;

    SET @out_raised_count = ISNULL(@checklist_count, 0) + ISNULL(@obligation_count, 0);
END;
GO

-- =====================================================================
-- 128's sp_event_raise_asset_lifecycle, verbatim.
-- =====================================================================
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

    DECLARE @checklist_count INT = 0, @obligation_count INT = 0;

    EXEC grac_practice.sp_event_instance_raise_scoped
         @organization_id = @organization_id, @event_code = @event_code,
         @subject_entity = N'ASSET', @subject_record_id = @asset_id,
         @effective_date = @effective_date, @trigger_source = @trigger_source,
         @actor_employee_id = @actor_employee_id,
         @out_raised_count = @checklist_count OUTPUT;

    IF EXISTS (SELECT 1 FROM GRAC_New.event_type_master
                WHERE event_code = @event_code AND status = N'Active')
        EXEC grac_practice.sp_event_obligation_raise
             @organization_id = @organization_id, @event_type_code = @event_code,
             @subject_entity = N'ASSET', @subject_record_id = @asset_id,
             @effective_date = @effective_date, @trigger_source = @trigger_source,
             @actor_employee_id = @actor_employee_id,
             @out_raised_count = @obligation_count OUTPUT;

    SET @out_raised_count = ISNULL(@checklist_count, 0) + ISNULL(@obligation_count, 0);
END;
GO

-- =====================================================================
-- Drop the helper LAST -- after the two wrappers above no longer call it.
-- =====================================================================
IF OBJECT_ID('grac_practice.sp_event_definition_ensure_baseline','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_event_definition_ensure_baseline;
GO

SELECT 'wrappers restored to 128' AS Check_,
       CASE WHEN NOT EXISTS (SELECT 1 FROM sys.sql_modules
                              WHERE object_id IN (
                                    OBJECT_ID('grac_practice.sp_event_raise_people_lifecycle'),
                                    OBJECT_ID('grac_practice.sp_event_raise_asset_lifecycle'))
                                AND definition LIKE N'%sp_event_definition_ensure_baseline%')
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT 'sp_event_definition_ensure_baseline dropped',
       CASE WHEN OBJECT_ID('grac_practice.sp_event_definition_ensure_baseline','P') IS NULL
            THEN 'PASS' ELSE 'FAIL' END;
GO

PRINT '335 rolled back. Event definition rows were deliberately kept -- see the header.';
GO

SET NOEXEC OFF;
GO
