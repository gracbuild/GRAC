-- =====================================================================
-- 124 Event scope mapping procedures -- ROLLBACK
--
-- Drops the procedures 124 introduced, then restores
-- sp_event_checklist_mapping_save to its 067 signature (no scope
-- parameters). Callers that pass the 124 parameters will fail after this
-- runs -- that is intended, and is why 124 must be rolled back before
-- 123, not after.
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.sp_event_resolution_trace_list','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_event_resolution_trace_list;
GO
IF OBJECT_ID('grac_practice.sp_event_instance_detail_get','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_event_instance_detail_get;
GO
IF OBJECT_ID('grac_practice.sp_event_checklist_inbox_list','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_event_checklist_inbox_list;
GO
IF OBJECT_ID('grac_practice.sp_event_raise_asset_lifecycle','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_event_raise_asset_lifecycle;
GO
IF OBJECT_ID('grac_practice.sp_event_raise_people_lifecycle','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_event_raise_people_lifecycle;
GO
IF OBJECT_ID('grac_practice.sp_event_instance_raise_scoped','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_event_instance_raise_scoped;
GO
IF OBJECT_ID('grac_practice.sp_event_scope_coverage_list','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_event_scope_coverage_list;
GO
IF OBJECT_ID('grac_practice.sp_event_scope_mapping_list','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_event_scope_mapping_list;
GO

-- ---------------------------------------------------------------------
-- Restore sp_event_checklist_mapping_save to the 067 definition.
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE grac_practice.sp_event_checklist_mapping_save
    @mapping_id              BIGINT = NULL,
    @organization_id         BIGINT,
    @entity_type_id          BIGINT,
    @event_definition_id     BIGINT,
    @checklist_id            BIGINT,
    @default_owner_role      NVARCHAR(100) = NULL,
    @default_due_period_days INT           = NULL,
    @status                  NVARCHAR(30)  = N'Active',
    @actor_employee_id       BIGINT        = NULL,
    @out_mapping_id          BIGINT        OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    IF @organization_id IS NULL OR @entity_type_id IS NULL
       OR @event_definition_id IS NULL OR @checklist_id IS NULL
        THROW 67070, 'sp_event_checklist_mapping_save: organization_id, entity_type_id, event_definition_id and checklist_id are required.', 1;

    IF @status NOT IN (N'Active', N'Inactive') SET @status = N'Active';

    DECLARE @actor NVARCHAR(100) = COALESCE(CAST(@actor_employee_id AS NVARCHAR(100)), 'api');

    IF @mapping_id IS NULL
    BEGIN
        INSERT INTO grac_practice.event_checklist_mapping
            (organization_id, entity_type_id, event_definition_id, checklist_id,
             default_owner_role, default_due_period_days, status,
             entered_by, entered_dt)
        VALUES
            (@organization_id, @entity_type_id, @event_definition_id, @checklist_id,
             @default_owner_role, @default_due_period_days, @status,
             @actor, SYSUTCDATETIME());
        SET @out_mapping_id = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        UPDATE grac_practice.event_checklist_mapping
           SET entity_type_id          = @entity_type_id,
               event_definition_id     = @event_definition_id,
               checklist_id            = @checklist_id,
               default_owner_role      = @default_owner_role,
               default_due_period_days = @default_due_period_days,
               status                  = @status,
               updated_by              = @actor,
               updated_dt              = SYSUTCDATETIME()
         WHERE mapping_id = @mapping_id;
        SET @out_mapping_id = @mapping_id;
    END
END;
GO

-- =====================================================================
-- Sanity report
-- =====================================================================
SELECT '124 procedures dropped' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.sp_event_instance_raise_scoped','P') IS NULL
             AND OBJECT_ID('grac_practice.sp_event_checklist_inbox_list','P') IS NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;
SELECT 'mapping_save restored to 067 signature' AS Check_,
       CASE WHEN NOT EXISTS (SELECT 1 FROM sys.parameters
                              WHERE object_id = OBJECT_ID('grac_practice.sp_event_checklist_mapping_save')
                                AND name = '@scope_role_id')
            THEN 'PASS' ELSE 'FAIL' END AS Result;

PRINT '124 Event scope mapping procedures rolled back.';
GO
