-- =====================================================================
-- 112 rollback -- drop all new custom_gap_* procs and restore pre-112
-- accept hook (points back at sp_org_assurance_gap_generate_from_observation).
-- =====================================================================
SET NOCOUNT ON;
GO

DROP PROCEDURE IF EXISTS grac_practice.sp_custom_gap_history_list;
DROP PROCEDURE IF EXISTS grac_practice.sp_custom_gap_action_delete;
DROP PROCEDURE IF EXISTS grac_practice.sp_custom_gap_action_complete;
DROP PROCEDURE IF EXISTS grac_practice.sp_custom_gap_action_save;
DROP PROCEDURE IF EXISTS grac_practice.sp_custom_gap_action_list;
DROP PROCEDURE IF EXISTS grac_practice.sp_custom_gap_merge;
DROP PROCEDURE IF EXISTS grac_practice.sp_observation_linked_custom_gaps_list;
DROP PROCEDURE IF EXISTS grac_practice.sp_custom_gap_observation_list;
DROP PROCEDURE IF EXISTS grac_practice.sp_custom_gap_observation_detach;
DROP PROCEDURE IF EXISTS grac_practice.sp_custom_gap_observation_attach;
DROP PROCEDURE IF EXISTS grac_practice.sp_custom_gap_reopen;
DROP PROCEDURE IF EXISTS grac_practice.sp_custom_gap_close_lifecycle;
DROP PROCEDURE IF EXISTS grac_practice.sp_custom_gap_verify;
DROP PROCEDURE IF EXISTS grac_practice.sp_custom_gap_submit_remediation;
DROP PROCEDURE IF EXISTS grac_practice.sp_custom_gap_start;
DROP PROCEDURE IF EXISTS grac_practice.sp_custom_gap_transition;
DROP PROCEDURE IF EXISTS grac_practice.sp_custom_gap_generate_from_assurance_observation;
DROP PROCEDURE IF EXISTS grac_practice.sp_custom_gap_delete;
DROP PROCEDURE IF EXISTS grac_practice.sp_custom_gap_save;
DROP PROCEDURE IF EXISTS grac_practice.sp_custom_gap_get;
GO

-- Restore sp_custom_gap_list to the pre-112 signature (055 version).
CREATE OR ALTER PROCEDURE grac_practice.sp_custom_gap_list
    @organization_id BIGINT       = NULL,
    @status_code     NVARCHAR(30) = NULL,
    @priority        NVARCHAR(30) = NULL,
    @owner_employee_id BIGINT     = NULL,
    @search          NVARCHAR(200) = NULL,
    @page            INT          = 1,
    @page_size       INT          = 25
AS
BEGIN
    SET NOCOUNT ON;
    IF @page IS NULL OR @page < 1 SET @page = 1;
    IF @page_size IS NULL OR @page_size < 1 SET @page_size = 25;
    IF @page_size > 200 SET @page_size = 200;

    ;WITH filtered AS (
        SELECT g.custom_gap_id, g.organization_id, g.gap_type_code,
               g.title, g.description, g.priority, g.owner_employee_id,
               g.due_date, g.status, g.remarks, g.linked_task_id,
               g.entered_by, g.entered_dt, g.updated_by, g.updated_dt
        FROM grac_practice.custom_gap g
        WHERE (@organization_id IS NULL OR g.organization_id = @organization_id)
          AND (@status_code     IS NULL OR g.status         = @status_code)
          AND (@priority        IS NULL OR g.priority       = @priority)
          AND (@owner_employee_id IS NULL OR g.owner_employee_id = @owner_employee_id)
          AND (@search          IS NULL
               OR g.title       LIKE N'%' + @search + N'%'
               OR g.description LIKE N'%' + @search + N'%'
               OR g.remarks     LIKE N'%' + @search + N'%')
    )
    SELECT (SELECT COUNT_BIG(*) FROM filtered) AS TotalCount,
           @page AS PageNumber, @page_size AS PageSize
    OPTION (RECOMPILE);

    ;WITH filtered AS (
        SELECT g.custom_gap_id, g.organization_id, g.gap_type_code,
               g.title, g.description, g.priority, g.owner_employee_id,
               g.due_date, g.status, g.remarks, g.linked_task_id,
               g.entered_by, g.entered_dt, g.updated_by, g.updated_dt
        FROM grac_practice.custom_gap g
        WHERE (@organization_id IS NULL OR g.organization_id = @organization_id)
          AND (@status_code     IS NULL OR g.status         = @status_code)
          AND (@priority        IS NULL OR g.priority       = @priority)
          AND (@owner_employee_id IS NULL OR g.owner_employee_id = @owner_employee_id)
          AND (@search          IS NULL
               OR g.title       LIKE N'%' + @search + N'%'
               OR g.description LIKE N'%' + @search + N'%'
               OR g.remarks     LIKE N'%' + @search + N'%')
    )
    SELECT * FROM filtered
    ORDER BY CASE WHEN due_date IS NULL THEN 1 ELSE 0 END, due_date ASC, custom_gap_id DESC
    OFFSET (@page - 1) * @page_size ROWS FETCH NEXT @page_size ROWS ONLY
    OPTION (RECOMPILE);
END
GO

-- Restore the pre-112 accept hook (points back at Assurance-side generator).
CREATE OR ALTER PROCEDURE grac_practice.sp_org_assurance_observation_accept
    @organization_id BIGINT, @observation_id BIGINT,
    @notes NVARCHAR(MAX) = NULL, @actor NVARCHAR(100) = 'system'
AS
BEGIN
    SET NOCOUNT ON;
    EXEC grac_practice.sp_org_assurance_observation_transition
        @organization_id = @organization_id, @observation_id = @observation_id,
        @expected_from_codes = N'InReview', @to_code = N'Accepted',
        @stamp_field = N'accepted', @notes = @notes, @actor = @actor;
    IF OBJECT_ID('grac_practice.sp_org_assurance_gap_generate_from_observation','P') IS NOT NULL
    BEGIN
        DECLARE @new_gap_id BIGINT;
        BEGIN TRY
            EXEC grac_practice.sp_org_assurance_gap_generate_from_observation
                @organization_id = @organization_id,
                @observation_id  = @observation_id,
                @actor           = @actor,
                @gap_id_out      = @new_gap_id OUTPUT;
        END TRY
        BEGIN CATCH
            PRINT N'accept: gap generation failed -- ' + ERROR_MESSAGE();
        END CATCH
    END
END
GO

PRINT '112 rollback complete.';
GO
