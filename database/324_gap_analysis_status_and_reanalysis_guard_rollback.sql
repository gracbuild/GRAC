-- =====================================================================
-- 324 rollback -- restores sp_custom_gap_open (250), sp_custom_gap_save
-- (116b), sp_custom_gap_analysis_save (323) and sp_gap_centre_list (318)
-- to their exact pre-324 bodies.
--
-- Existing custom_gap rows that 324 stamped with a lifecycle_state_id at
-- creation are NOT unstamped -- this rollback undoes the proc bodies
-- only, exactly like every other rollback in this project (data already
-- written by the corrected procs is not un-written). A gap created while
-- 324 was active keeps its lifecycle_state_id after rollback; it simply
-- goes back to being possible (again) for a NEWLY created gap to be born
-- with a NULL one.
--
-- ASCII-only. Safe to re-run.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

-- =====================================================================
-- 1. sp_custom_gap_open -- restored to 250's exact body
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_custom_gap_open
    @organization_id        BIGINT,
    @title                  NVARCHAR(250),
    @description            NVARCHAR(MAX) = NULL,
    @priority               NVARCHAR(30)  = N'Medium',
    @owner_employee_id      BIGINT        = NULL,
    @due_date               DATE          = NULL,
    @status                 NVARCHAR(30)  = N'Open',
    @remarks                NVARCHAR(1000) = NULL,
    @gap_type_code          NVARCHAR(60)  = N'Custom',
    @actor_employee_id      BIGINT        = NULL,
    @severity_code          NVARCHAR(30)  = NULL,
    @severity_name          NVARCHAR(120) = NULL,
    @detection_method_code  NVARCHAR(60)  = NULL,
    @detection_method_name  NVARCHAR(200) = NULL,
    @custom_gap_id          BIGINT        OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    IF @organization_id IS NULL OR @title IS NULL OR LTRIM(RTRIM(@title)) = N''
        THROW 54010, 'sp_custom_gap_open: organization_id and title are required.', 1;

    IF @priority NOT IN (N'Low', N'Medium', N'High', N'Critical')
        SET @priority = N'Medium';

    IF @status NOT IN (N'Open', N'InProgress', N'Closed', N'Cancelled')
        SET @status = N'Open';

    IF @severity_code IS NOT NULL AND @severity_code NOT IN (N'Low', N'Medium', N'High', N'Critical')
        SET @severity_code = NULL;
    IF @severity_code IS NULL
        SET @severity_code = @priority;
    IF @severity_name IS NULL
        SET @severity_name = @severity_code;

    INSERT INTO grac_practice.custom_gap
        (organization_id, gap_type_code, title, description, priority,
         owner_employee_id, due_date, status, remarks,
         severity_code, severity_name,
         detection_method_code, detection_method_name,
         entered_by, entered_dt)
    VALUES
        (@organization_id, ISNULL(@gap_type_code, N'Custom'),
         @title, @description, @priority,
         @owner_employee_id, @due_date, @status, @remarks,
         @severity_code, @severity_name,
         NULLIF(LTRIM(RTRIM(@detection_method_code)), N''),
         NULLIF(LTRIM(RTRIM(@detection_method_name)), N''),
         COALESCE(CAST(@actor_employee_id AS NVARCHAR(100)), 'api'),
         SYSUTCDATETIME());

    SET @custom_gap_id = SCOPE_IDENTITY();
END
GO

-- =====================================================================
-- 2. sp_custom_gap_save -- restored to 116b's exact body
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_custom_gap_save
    @organization_id                BIGINT,
    @custom_gap_id                  BIGINT       = NULL,
    @gap_source_module_code         NVARCHAR(30) = N'Custom',
    @source_reference_type          NVARCHAR(60) = NULL,
    @source_reference_id            BIGINT       = NULL,
    @gap_type_code                  NVARCHAR(60) = NULL,
    @title                          NVARCHAR(250),
    @description                    NVARCHAR(MAX) = NULL,
    @priority                       NVARCHAR(30) = N'Medium',
    @severity_code                  NVARCHAR(30) = NULL,
    @severity_name                  NVARCHAR(120) = NULL,
    @owner_employee_id              BIGINT       = NULL,
    @owner_display_name             NVARCHAR(240) = NULL,
    @assigned_reviewer_employee_id  BIGINT       = NULL,
    @assigned_reviewer_display_name NVARCHAR(240) = NULL,
    @due_date                       DATE         = NULL,
    @target_resolution_date         DATE         = NULL,
    @remediation_plan               NVARCHAR(MAX) = NULL,
    @remarks                        NVARCHAR(1000) = NULL,
    @owner_role_id                  BIGINT       = NULL,
    @owner_role_name                NVARCHAR(120) = NULL,
    @assigned_reviewer_role_id      BIGINT       = NULL,
    @assigned_reviewer_role_name    NVARCHAR(120) = NULL,
    @actor                          NVARCHAR(100) = 'system',
    @custom_gap_id_out              BIGINT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @organization_id IS NULL
        THROW 55001, 'organization_id is required.', 1;
    IF @title IS NULL OR LEN(LTRIM(RTRIM(@title))) = 0
        THROW 55002, 'title is required.', 1;
    IF @gap_source_module_code NOT IN (
            N'Implementation', N'Assurance', N'Custom',
            N'Exception', N'Risk', N'Audit')
        THROW 55003, 'gap_source_module_code must be a known source.', 1;
    IF @priority NOT IN (N'Low', N'Medium', N'High', N'Critical')
        SET @priority = N'Medium';

    IF @owner_role_id IS NOT NULL
       AND (@owner_role_name IS NULL OR LEN(LTRIM(RTRIM(@owner_role_name))) = 0)
        SELECT @owner_role_name = role_name
        FROM grac_practice.organization_role
        WHERE role_id = @owner_role_id AND organization_id = @organization_id;

    IF @owner_role_id IS NOT NULL AND @owner_employee_id IS NULL
        EXEC grac_practice.sp_org_role_primary_holder_pick
             @organization_id      = @organization_id,
             @role_id              = @owner_role_id,
             @employee_id_out      = @owner_employee_id     OUTPUT,
             @employee_name_out    = @owner_display_name    OUTPUT;

    IF @owner_employee_id IS NOT NULL AND @owner_role_id IS NULL
    BEGIN
        SELECT @owner_role_id = e.role_id,
               @owner_role_name = r.role_name
        FROM grac_practice.organization_employee e
        LEFT JOIN grac_practice.organization_role r ON r.role_id = e.role_id
        WHERE e.employee_id = @owner_employee_id
          AND e.organization_id = @organization_id;
    END

    IF @owner_employee_id IS NOT NULL
       AND (@owner_display_name IS NULL OR LEN(LTRIM(RTRIM(@owner_display_name))) = 0)
        SELECT @owner_display_name = employee_name
        FROM grac_practice.organization_employee
        WHERE employee_id = @owner_employee_id;

    IF @assigned_reviewer_role_id IS NOT NULL
       AND (@assigned_reviewer_role_name IS NULL OR LEN(LTRIM(RTRIM(@assigned_reviewer_role_name))) = 0)
        SELECT @assigned_reviewer_role_name = role_name
        FROM grac_practice.organization_role
        WHERE role_id = @assigned_reviewer_role_id AND organization_id = @organization_id;

    IF @assigned_reviewer_role_id IS NOT NULL AND @assigned_reviewer_employee_id IS NULL
        EXEC grac_practice.sp_org_role_primary_holder_pick
             @organization_id      = @organization_id,
             @role_id              = @assigned_reviewer_role_id,
             @employee_id_out      = @assigned_reviewer_employee_id   OUTPUT,
             @employee_name_out    = @assigned_reviewer_display_name  OUTPUT;

    IF @assigned_reviewer_employee_id IS NOT NULL AND @assigned_reviewer_role_id IS NULL
    BEGIN
        SELECT @assigned_reviewer_role_id = e.role_id,
               @assigned_reviewer_role_name = r.role_name
        FROM grac_practice.organization_employee e
        LEFT JOIN grac_practice.organization_role r ON r.role_id = e.role_id
        WHERE e.employee_id = @assigned_reviewer_employee_id
          AND e.organization_id = @organization_id;
    END

    IF @assigned_reviewer_employee_id IS NOT NULL
       AND (@assigned_reviewer_display_name IS NULL OR LEN(LTRIM(RTRIM(@assigned_reviewer_display_name))) = 0)
        SELECT @assigned_reviewer_display_name = employee_name
        FROM grac_practice.organization_employee
        WHERE employee_id = @assigned_reviewer_employee_id;

    BEGIN TRAN;

    IF @custom_gap_id IS NULL
    BEGIN
        INSERT INTO grac_practice.custom_gap(
            organization_id, gap_type_code,
            gap_source_module_code, source_reference_type, source_reference_id,
            title, description, priority, severity_code, severity_name,
            owner_employee_id, owner_display_name,
            owner_role_id, owner_role_name,
            assigned_reviewer_employee_id, assigned_reviewer_display_name,
            assigned_reviewer_role_id, assigned_reviewer_role_name,
            due_date, target_resolution_date,
            status, opened_dt,
            remediation_plan, remarks,
            entered_by, entered_dt)
        VALUES(
            @organization_id, ISNULL(@gap_type_code, @gap_source_module_code),
            @gap_source_module_code, @source_reference_type, @source_reference_id,
            @title, @description, @priority, @severity_code, @severity_name,
            @owner_employee_id, @owner_display_name,
            @owner_role_id, @owner_role_name,
            @assigned_reviewer_employee_id, @assigned_reviewer_display_name,
            @assigned_reviewer_role_id, @assigned_reviewer_role_name,
            @due_date, @target_resolution_date,
            N'Open', SYSUTCDATETIME(),
            @remediation_plan, @remarks,
            @actor, SYSUTCDATETIME());

        SET @custom_gap_id_out = SCOPE_IDENTITY();

        INSERT INTO grac_practice.custom_gap_history(
            custom_gap_id, organization_id, action_code,
            from_status_code, to_status_code,
            reason_text, actor_display_name, entered_by)
        VALUES(
            @custom_gap_id_out, @organization_id, N'CREATE',
            NULL, N'Open', N'Gap created.', @actor, @actor);
    END
    ELSE
    BEGIN
        DECLARE @gap_org BIGINT, @current_status NVARCHAR(60);
        SELECT @gap_org = organization_id, @current_status = status
        FROM grac_practice.custom_gap
        WHERE custom_gap_id = @custom_gap_id;

        IF @gap_org IS NULL       BEGIN ROLLBACK; THROW 55004, 'Gap not found.', 1; END
        IF @gap_org <> @organization_id
            BEGIN ROLLBACK; THROW 55005, 'Gap belongs to a different organization.', 1; END
        IF @current_status NOT IN (N'Open', N'InProgress', N'Reopened')
            BEGIN ROLLBACK; THROW 55006, 'Gap cannot be edited in its current status.', 1; END

        UPDATE grac_practice.custom_gap
        SET title                          = @title,
            description                    = @description,
            priority                       = @priority,
            severity_code                  = @severity_code,
            severity_name                  = @severity_name,
            owner_employee_id              = @owner_employee_id,
            owner_display_name             = @owner_display_name,
            owner_role_id                  = @owner_role_id,
            owner_role_name                = @owner_role_name,
            assigned_reviewer_employee_id  = @assigned_reviewer_employee_id,
            assigned_reviewer_display_name = @assigned_reviewer_display_name,
            assigned_reviewer_role_id      = @assigned_reviewer_role_id,
            assigned_reviewer_role_name    = @assigned_reviewer_role_name,
            due_date                       = @due_date,
            target_resolution_date         = @target_resolution_date,
            remediation_plan               = @remediation_plan,
            remarks                        = @remarks,
            updated_by                     = @actor,
            updated_dt                     = SYSUTCDATETIME()
        WHERE custom_gap_id = @custom_gap_id;

        SET @custom_gap_id_out = @custom_gap_id;

        INSERT INTO grac_practice.custom_gap_history(
            custom_gap_id, organization_id, action_code,
            from_status_code, to_status_code,
            reason_text, actor_display_name, entered_by)
        VALUES(
            @custom_gap_id, @organization_id, N'EDIT',
            @current_status, @current_status, N'Gap edited.', @actor, @actor);
    END

    COMMIT;
END
GO

-- =====================================================================
-- 3. sp_custom_gap_analysis_save -- restored to 323's exact body
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_custom_gap_analysis_save
    @custom_gap_id            BIGINT,
    @detection_method_code    NVARCHAR(60)  = NULL,
    @detection_method_name    NVARCHAR(200) = NULL,
    @severity_code            NVARCHAR(30)  = NULL,
    @severity_name            NVARCHAR(120) = NULL,
    @business_impact_code     NVARCHAR(30)  = NULL,
    @business_impact_summary  NVARCHAR(MAX) = NULL,
    @regulatory_impact_code   NVARCHAR(30)  = NULL,
    @regulatory_impact_summary NVARCHAR(MAX) = NULL,
    @rca_required             BIT           = 0,
    @rca_method_code          NVARCHAR(60)  = NULL,
    @rca_summary              NVARCHAR(MAX) = NULL,
    @recommended_action_summary NVARCHAR(MAX) = NULL,
    @preventive_action        NVARCHAR(MAX) = NULL,
    @recommend_task           BIT           = 0,
    @recommend_exception      BIT           = 0,
    @recommend_risk           BIT           = 0,
    @remediation_possible     CHAR(1)       = NULL,
    @business_risk_present    CHAR(1)       = NULL,
    @analysed_by_employee_id  BIGINT        = NULL,
    @caller_display_name      NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;

    IF @custom_gap_id IS NULL
        THROW 55121, 'sp_custom_gap_analysis_save: custom_gap_id is required.', 1;
    IF NOT EXISTS(SELECT 1 FROM grac_practice.custom_gap WHERE custom_gap_id = @custom_gap_id)
        THROW 55122, 'sp_custom_gap_analysis_save: custom_gap not found.', 1;

    IF EXISTS (
        SELECT 1
          FROM grac_practice.custom_gap g
          JOIN grac_practice.gap_lifecycle_state_master s ON s.lifecycle_state_id = g.lifecycle_state_id
         WHERE g.custom_gap_id = @custom_gap_id
           AND s.is_terminal = 1 AND s.is_valid_terminal = 0)
        THROW 55142, 'sp_custom_gap_analysis_save: gap is in a terminal-invalid state (e.g., Invalid/Duplicate); analysis is not applicable.', 1;

    IF @remediation_possible IS NOT NULL AND @remediation_possible NOT IN ('Y','N')
        THROW 55140, 'sp_custom_gap_analysis_save: remediation_possible must be Y or N.', 1;
    IF @business_risk_present IS NOT NULL AND @business_risk_present NOT IN ('Y','N')
        THROW 55141, 'sp_custom_gap_analysis_save: business_risk_present must be Y or N.', 1;

    SET @recommend_task      = ISNULL(@recommend_task, 0);
    SET @recommend_exception = ISNULL(@recommend_exception, 0);
    SET @recommend_risk      = ISNULL(@recommend_risk, 0);

    MERGE grac_practice.custom_gap_analysis AS tgt
    USING (SELECT @custom_gap_id AS custom_gap_id) AS src
    ON tgt.custom_gap_id = src.custom_gap_id
    WHEN MATCHED THEN UPDATE SET
        detection_method_code    = @detection_method_code,
        detection_method_name    = @detection_method_name,
        severity_code            = @severity_code,
        severity_name            = @severity_name,
        business_impact_code     = @business_impact_code,
        business_impact_summary  = @business_impact_summary,
        regulatory_impact_code   = @regulatory_impact_code,
        regulatory_impact_summary= @regulatory_impact_summary,
        rca_required             = @rca_required,
        rca_method_code          = @rca_method_code,
        rca_summary              = @rca_summary,
        recommended_action_summary = @recommended_action_summary,
        preventive_action        = COALESCE(@preventive_action, tgt.preventive_action),
        recommend_task           = @recommend_task,
        recommend_exception      = @recommend_exception,
        recommend_risk           = @recommend_risk,
        remediation_possible     = COALESCE(@remediation_possible, tgt.remediation_possible),
        business_risk_present    = COALESCE(@business_risk_present, tgt.business_risk_present),
        analysed_by_employee_id  = COALESCE(@analysed_by_employee_id, tgt.analysed_by_employee_id),
        analysed_on              = COALESCE(tgt.analysed_on, SYSUTCDATETIME()),
        updated_by               = @caller_display_name,
        updated_dt               = SYSUTCDATETIME()
    WHEN NOT MATCHED THEN INSERT
        (custom_gap_id, detection_method_code, detection_method_name,
         severity_code, severity_name,
         business_impact_code, business_impact_summary,
         regulatory_impact_code, regulatory_impact_summary,
         rca_required, rca_method_code, rca_summary,
         recommended_action_summary,
         preventive_action,
         recommend_task, recommend_exception, recommend_risk,
         remediation_possible, business_risk_present,
         analysed_by_employee_id, analysed_on,
         entered_by, entered_dt)
    VALUES
        (@custom_gap_id, @detection_method_code, @detection_method_name,
         @severity_code, @severity_name,
         @business_impact_code, @business_impact_summary,
         @regulatory_impact_code, @regulatory_impact_summary,
         @rca_required, @rca_method_code, @rca_summary,
         @recommended_action_summary,
         @preventive_action,
         @recommend_task, @recommend_exception, @recommend_risk,
         ISNULL(@remediation_possible, 'N'), ISNULL(@business_risk_present, 'N'),
         @analysed_by_employee_id, SYSUTCDATETIME(),
         @caller_display_name, SYSUTCDATETIME());

    IF @severity_code IS NOT NULL AND LEN(LTRIM(RTRIM(@severity_code))) > 0
        UPDATE grac_practice.custom_gap
           SET severity_code = @severity_code,
               severity_name = COALESCE(@severity_name, severity_name),
               updated_by    = @caller_display_name,
               updated_dt    = SYSUTCDATETIME()
         WHERE custom_gap_id = @custom_gap_id;

    DECLARE @task_created      BIT = 0, @task_error      NVARCHAR(4000) = NULL;
    DECLARE @exception_created BIT = 0, @exception_error NVARCHAR(4000) = NULL;
    DECLARE @risk_created      BIT = 0, @risk_error      NVARCHAR(4000) = NULL;

    IF @recommend_task = 1
    BEGIN
        BEGIN TRY
            EXEC grac_practice.sp_custom_gap_task_create
                @custom_gap_id           = @custom_gap_id,
                @assigned_to_employee_id = @analysed_by_employee_id,
                @caller_display_name     = @caller_display_name;
            SET @task_created = 1;
        END TRY
        BEGIN CATCH
            SET @task_error = ERROR_MESSAGE();
            PRINT CONCAT(N'sp_custom_gap_analysis_save: task auto-create warning: ', @task_error);
        END CATCH
    END

    IF @recommend_exception = 1
    BEGIN
        BEGIN TRY
            EXEC grac_practice.sp_exception_request_create
                @custom_gap_id            = @custom_gap_id,
                @request_title            = NULL,
                @request_reason           = @recommended_action_summary,
                @requested_by_employee_id = @analysed_by_employee_id,
                @caller_display_name      = @caller_display_name;
            SET @exception_created = 1;
        END TRY
        BEGIN CATCH
            SET @exception_error = ERROR_MESSAGE();
            PRINT CONCAT(N'sp_custom_gap_analysis_save: exception auto-create warning: ', @exception_error);
        END CATCH
    END

    IF @recommend_risk = 1
    BEGIN
        BEGIN TRY
            EXEC grac_practice.sp_risk_candidate_create
                @custom_gap_id            = @custom_gap_id,
                @candidate_title          = NULL,
                @candidate_summary        = @recommended_action_summary,
                @severity_code            = @severity_code,
                @severity_name            = @severity_name,
                @impact_summary           = @business_impact_summary,
                @likelihood_summary       = @regulatory_impact_summary,
                @requested_by_employee_id = @analysed_by_employee_id,
                @caller_display_name      = @caller_display_name;
            SET @risk_created = 1;
        END TRY
        BEGIN CATCH
            SET @risk_error = ERROR_MESSAGE();
            PRINT CONCAT(N'sp_custom_gap_analysis_save: risk auto-create warning: ', @risk_error);
        END CATCH
    END

    BEGIN TRY
        DECLARE @current_state_code NVARCHAR(60);
        SELECT @current_state_code = s.state_code
          FROM grac_practice.custom_gap g
          JOIN grac_practice.gap_lifecycle_state_master s ON s.lifecycle_state_id = g.lifecycle_state_id
         WHERE g.custom_gap_id = @custom_gap_id;

        IF @current_state_code IN (N'New', N'Validation', N'Analysis')
        BEGIN
            EXEC grac_practice.sp_custom_gap_lifecycle_transition
                @custom_gap_id       = @custom_gap_id,
                @action_code         = N'Delegate',
                @remark              = N'Auto-delegated after analysis save.',
                @caller_employee_id  = @analysed_by_employee_id,
                @caller_display_name = @caller_display_name;
        END
    END TRY
    BEGIN CATCH
        DECLARE @msg_del NVARCHAR(4000) = ERROR_MESSAGE();
        PRINT CONCAT(N'sp_custom_gap_analysis_save: auto-delegate warning: ', @msg_del);
    END CATCH

    SELECT @custom_gap_id AS CustomGapId;

    SELECT
        @task_created      AS TaskCreated,      @task_error      AS TaskError,
        @exception_created AS ExceptionCreated, @exception_error AS ExceptionError,
        @risk_created      AS RiskCreated,      @risk_error      AS RiskError;
END
GO

-- =====================================================================
-- 4. sp_gap_centre_list -- restored to 318's exact body
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_gap_centre_list
    @organization_id     BIGINT        = NULL,
    @source_module_code  NVARCHAR(30)  = NULL,
    @status_code         NVARCHAR(30)  = NULL,
    @search              NVARCHAR(200) = NULL,
    @observation_id      BIGINT        = NULL,
    @page                INT           = 1,
    @page_size           INT           = 25
AS
BEGIN
    SET NOCOUNT ON;

    IF @page IS NULL OR @page < 1 SET @page = 1;
    IF @page_size IS NULL OR @page_size < 1 SET @page_size = 25;
    IF @page_size > 200 SET @page_size = 200;
    IF @search = N'' SET @search = NULL;
    IF @source_module_code = N'' SET @source_module_code = NULL;
    IF @status_code = N'' SET @status_code = NULL;

    DECLARE @results TABLE (
        RowKey             NVARCHAR(40)  NOT NULL,
        SourceModuleCode   NVARCHAR(30)  NOT NULL,
        CustomGapId        BIGINT        NULL,
        PracticeGapId      BIGINT        NULL,
        PracticeInstanceId BIGINT        NULL,
        IsMaterialized     BIT           NOT NULL,
        Title              NVARCHAR(400) NULL,
        Context            NVARCHAR(800) NULL,
        StatusText         NVARCHAR(100) NULL,
        RawStatusCode      NVARCHAR(30)  NULL,
        SeverityText       NVARCHAR(200) NULL,
        OwnerText          NVARCHAR(300) NULL,
        DueDate            DATE          NULL,
        OpenedDt           DATETIME2(3)  NULL,
        LinkedCount        INT           NOT NULL,
        InstanceCode       NVARCHAR(100) NULL,
        InstanceName       NVARCHAR(300) NULL,
        ExistingTaskCount  INT           NOT NULL,
        SortBucket         INT           NOT NULL
    );

    INSERT INTO @results
        (RowKey, SourceModuleCode, CustomGapId, PracticeGapId, PracticeInstanceId,
         IsMaterialized, Title, Context, StatusText, RawStatusCode, SeverityText, OwnerText,
         DueDate, OpenedDt, LinkedCount,
         InstanceCode, InstanceName, ExistingTaskCount, SortBucket)
    SELECT
        N'cg' + CAST(g.custom_gap_id AS NVARCHAR(20)),
        g.gap_source_module_code,
        g.custom_gap_id,
        NULL,
        CASE WHEN g.source_reference_type = N'PracticeInstance'
             THEN g.source_reference_id ELSE NULL END,
        1,
        g.title,
        NULLIF(LTRIM(RTRIM(CONCAT(
            ISNULL(g.execution_name, N''),
            CASE WHEN g.execution_name IS NOT NULL AND g.entity_name IS NOT NULL
                 THEN N' / ' ELSE N'' END,
            ISNULL(g.entity_name, N'')))), N''),
        COALESCE(s.state_name, g.status),
        g.status,
        COALESCE(g.severity_name, g.severity_code, g.priority),
        g.owner_display_name,
        CAST(COALESCE(g.due_date, g.target_resolution_date) AS DATE),
        g.opened_dt,
        (SELECT COUNT(*) FROM grac_practice.custom_gap_observation j
          WHERE j.custom_gap_id = g.custom_gap_id AND j.is_active = 1),
        NULL, NULL,
        (SELECT COUNT(*)
           FROM grac_practice.practice_task t
          WHERE t.subject_entity_type = N'CustomGap'
            AND t.subject_entity_id   = g.custom_gap_id
            AND t.closed_at IS NULL),
        1
    FROM   grac_practice.custom_gap g
    LEFT   JOIN grac_practice.gap_lifecycle_state_master s ON s.lifecycle_state_id = g.lifecycle_state_id
    WHERE (@organization_id IS NULL    OR g.organization_id        = @organization_id)
      AND (@source_module_code IS NULL OR g.gap_source_module_code = @source_module_code)
      AND (@status_code IS NULL        OR g.status                 = @status_code)
      AND (@observation_id IS NULL OR EXISTS (
                SELECT 1 FROM grac_practice.custom_gap_observation j
                 WHERE j.custom_gap_id                = g.custom_gap_id
                   AND j.org_assurance_observation_id = @observation_id
                   AND j.is_active                    = 1))
      AND (@search IS NULL
           OR g.title             LIKE N'%' + @search + N'%'
           OR g.description       LIKE N'%' + @search + N'%'
           OR g.execution_name    LIKE N'%' + @search + N'%'
           OR g.entity_name       LIKE N'%' + @search + N'%'
           OR g.observation_title LIKE N'%' + @search + N'%');

    IF (@source_module_code IS NULL OR @source_module_code = N'Implementation')
       AND @observation_id IS NULL
    INSERT INTO @results
        (RowKey, SourceModuleCode, CustomGapId, PracticeGapId, PracticeInstanceId,
         IsMaterialized, Title, Context, StatusText, RawStatusCode, SeverityText, OwnerText,
         DueDate, OpenedDt, LinkedCount,
         InstanceCode, InstanceName, ExistingTaskCount, SortBucket)
    SELECT
        N'pg' + CAST(pg.practice_gap_id AS NVARCHAR(20)),
        N'Implementation',
        NULL,
        pg.practice_gap_id,
        pi.practice_instance_id,
        0,
        COALESCE(pi.instance_name, pi.instance_code),
        NULLIF(LTRIM(RTRIM(CONCAT(
            ISNULL(pi.instance_code, N''),
            CASE WHEN pi.instance_code IS NOT NULL AND p.practice_name IS NOT NULL
                 THEN N' / ' ELSE N'' END,
            ISNULL(p.practice_name, N'')))), N''),
        (SELECT CASE MIN(CASE pgo.logged_status_code
                              WHEN N'Not Implemented'       THEN 1
                              WHEN N'Partially Implemented' THEN 2
                              ELSE 3 END)
                     WHEN 1 THEN N'Not Implemented'
                     WHEN 2 THEN N'Partially Implemented'
                     ELSE N'Open'
                 END
           FROM  grac_practice.practice_gap_obligation pgo
           WHERE pgo.practice_gap_id = pg.practice_gap_id
             AND pgo.status          = N'Active'),
        NULL,
        pi.criticality,
        pi.primary_owner,
        NULL,
        pg.opened_dt,
        (SELECT COUNT(*) FROM grac_practice.practice_gap_obligation pgo
          WHERE pgo.practice_gap_id = pg.practice_gap_id
            AND pgo.status          = N'Active'),
        pi.instance_code,
        pi.instance_name,
        (SELECT COUNT(*)
           FROM grac_practice.practice_task t
           JOIN grac_practice.task_type_master tt ON tt.task_type_id = t.task_type_id
          WHERE t.subject_entity_type = N'PracticeInstance'
            AND t.subject_entity_id   = pi.practice_instance_id
            AND tt.type_code          = N'Implementation'
            AND t.closed_at IS NULL),
        0
    FROM   grac_practice.practice_gap pg
    JOIN   grac_practice.practice_instance pi
           ON pi.practice_instance_id = pg.practice_instance_id
    LEFT   JOIN grac_practice.practice p ON p.practice_id = pi.practice_id
    WHERE (@organization_id IS NULL OR pi.organization_id = @organization_id)
      AND  pg.gap_status = N'Open'
      AND  NOT EXISTS (
               SELECT 1
                 FROM grac_practice.custom_gap cg
                WHERE cg.source_reference_type = N'PracticeInstance'
                  AND cg.source_reference_id   = pg.practice_instance_id
                  AND cg.organization_id       = pi.organization_id)
      AND (@search IS NULL
           OR pi.instance_code LIKE N'%' + @search + N'%'
           OR pi.instance_name LIKE N'%' + @search + N'%'
           OR p.practice_name  LIKE N'%' + @search + N'%')
      AND (@status_code IS NULL
           OR @status_code = N'Open'
           OR EXISTS (SELECT 1
                        FROM grac_practice.practice_gap_obligation pgo
                       WHERE pgo.practice_gap_id    = pg.practice_gap_id
                         AND pgo.status             = N'Active'
                         AND pgo.logged_status_code = @status_code));

    SELECT COUNT_BIG(*) AS TotalCount,
           @page        AS PageNumber,
           @page_size   AS PageSize
    FROM   @results;

    SELECT RowKey, SourceModuleCode, CustomGapId, PracticeGapId,
           PracticeInstanceId, IsMaterialized, Title, Context,
           StatusText, RawStatusCode, SeverityText, OwnerText, DueDate, OpenedDt,
           LinkedCount, InstanceCode, InstanceName, ExistingTaskCount
    FROM   @results
    ORDER  BY SortBucket,
              CASE StatusText
                   WHEN N'Not Implemented'       THEN 1
                   WHEN N'Partially Implemented' THEN 2
                   ELSE 3
              END,
              OpenedDt DESC,
              RowKey
    OFFSET (@page - 1) * @page_size ROWS
    FETCH NEXT @page_size ROWS ONLY;
END
GO

PRINT '324 rollback complete. sp_custom_gap_open/sp_custom_gap_save/sp_custom_gap_analysis_save/sp_gap_centre_list restored to their pre-324 bodies.';
GO

SET NOEXEC OFF;
GO
