-- =====================================================================
-- 372 rollback -- restores both procs to their exact pre-372 bodies:
--   * sp_custom_gap_linked_artefacts -> 317's exact body (no
--     CurrentStatusCode column).
--   * sp_custom_gap_analysis_save    -> 367's exact body (guard 55144
--     blocks on ANY Active practice_gap_obligation child again, not
--     just Not Started).
-- SAFE TO RE-RUN. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.sp_custom_gap_linked_artefacts','P') IS NULL
BEGIN PRINT 'ABORT (372 rollback): sp_custom_gap_linked_artefacts missing.'; SET NOEXEC ON; END
GO
IF OBJECT_ID('grac_practice.sp_custom_gap_analysis_save','P') IS NULL
BEGIN PRINT 'ABORT (372 rollback): sp_custom_gap_analysis_save missing.'; SET NOEXEC ON; END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_custom_gap_linked_artefacts
    @custom_gap_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF @custom_gap_id IS NULL
        THROW 55510, 'sp_custom_gap_linked_artefacts: custom_gap_id is required.', 1;

    -- Task
    SELECT TOP 1
        N'Task'                     AS ArtefactType,
        t.task_id                   AS ArtefactId,
        t.subject_title             AS Title,
        s.status_code               AS StatusCode
      FROM grac_practice.practice_task t
      JOIN grac_practice.entity_status_master s ON s.entity_status_id = t.current_status_id
     WHERE t.subject_entity_type = N'CustomGap'
       AND t.subject_entity_id   = @custom_gap_id
     ORDER BY t.task_id DESC;

    -- Exception
    SELECT TOP 1
        N'Exception'                AS ArtefactType,
        e.exception_request_id      AS ArtefactId,
        e.request_title             AS Title,
        e.status_code               AS StatusCode
      FROM grac_practice.exception_request e
     WHERE e.custom_gap_id = @custom_gap_id
     ORDER BY e.exception_request_id DESC;

    -- Risk
    SELECT TOP 1
        N'RiskCandidate'            AS ArtefactType,
        r.risk_candidate_id         AS ArtefactId,
        r.candidate_title           AS Title,
        r.status_code               AS StatusCode
      FROM grac_practice.risk_candidate r
     WHERE r.custom_gap_id = @custom_gap_id
     ORDER BY r.risk_candidate_id DESC;

    -- Failed Obligation(s) -- migration 317.
    SELECT pgo.practice_instance_obligation_id AS ObligationId,
           pgo.obligation_name                 AS ObligationName,
           pgo.obligation_type_code            AS ObligationTypeCode,
           pgo.logged_status_code              AS LoggedStatusCode,
           pgo.added_dt                        AS AddedDt
      FROM grac_practice.custom_gap cg
      JOIN grac_practice.practice_gap pg
           ON pg.practice_instance_id = cg.source_reference_id
      JOIN grac_practice.practice_gap_obligation pgo
           ON pgo.practice_gap_id = pg.practice_gap_id
          AND pgo.status         = N'Active'
     WHERE cg.custom_gap_id          = @custom_gap_id
       AND cg.gap_source_module_code = N'Implementation'
       AND cg.source_reference_type  = N'PracticeInstance'
       AND cg.source_reference_id   IS NOT NULL
     ORDER BY CASE pgo.logged_status_code
                   WHEN N'Not Implemented'       THEN 1
                   WHEN N'Partially Implemented' THEN 2
                   ELSE 3 END,
              pgo.obligation_name;
END
GO

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

    -- Terminal-invalid guard (from 173).
    IF EXISTS (
        SELECT 1
          FROM grac_practice.custom_gap g
          JOIN grac_practice.gap_lifecycle_state_master s ON s.lifecycle_state_id = g.lifecycle_state_id
         WHERE g.custom_gap_id = @custom_gap_id
           AND s.is_terminal = 1 AND s.is_valid_terminal = 0)
        THROW 55142, 'sp_custom_gap_analysis_save: gap is in a terminal-invalid state (e.g., Invalid/Duplicate); analysis is not applicable.', 1;

    -- Migration 324: terminal-VALID guard.
    IF EXISTS (
        SELECT 1
          FROM grac_practice.custom_gap g
          LEFT JOIN grac_practice.gap_lifecycle_state_master s ON s.lifecycle_state_id = g.lifecycle_state_id
         WHERE g.custom_gap_id = @custom_gap_id
           AND s.is_terminal = 1 AND s.is_valid_terminal = 1)
        THROW 55143, 'sp_custom_gap_analysis_save: this gap has already been analysed; re-analysis is not allowed. Open it in View mode to see the saved analysis.', 1;

    -- Migration 367: Implementation/PracticeInstance-sourced gap guards.
    DECLARE @src_module NVARCHAR(30), @src_type NVARCHAR(60), @src_instance_id BIGINT;
    SELECT @src_module      = g.gap_source_module_code,
           @src_type        = g.source_reference_type,
           @src_instance_id = g.source_reference_id
      FROM grac_practice.custom_gap g
     WHERE g.custom_gap_id = @custom_gap_id;

    IF @src_module = N'Implementation' AND @src_type = N'PracticeInstance' AND @src_instance_id IS NOT NULL
    BEGIN
        IF EXISTS (
            SELECT 1
              FROM grac_practice.practice_gap pg
              JOIN grac_practice.practice_gap_obligation pgo
                   ON pgo.practice_gap_id = pg.practice_gap_id
                  AND pgo.status          = N'Active'
             WHERE pg.practice_instance_id = @src_instance_id)
            THROW 55144, 'sp_custom_gap_analysis_save: one or more obligations displayed under this gap are still unresolved (Not Implemented / Partially Implemented / Not Set); resolve them before this gap can be analysed.', 1;

        DECLARE @total_dep_categories INT, @resolved_dep_count INT, @is_operationalized BIT;

        SELECT @total_dep_categories = COUNT(DISTINCT d.dependency_type_id)
          FROM grac_practice.practice_instance_dependency d
         WHERE d.practice_instance_id = @src_instance_id
           AND d.status               = N'Active'
           AND d.dependency_type_id  IS NOT NULL;

        SELECT @resolved_dep_count = COUNT(*)
          FROM grac_practice.practice_dependency_resolution r
         WHERE r.practice_instance_id = @src_instance_id
           AND r.is_active            = 1;

        SET @is_operationalized = CASE
            WHEN EXISTS (
                     SELECT 1
                       FROM grac_practice.practice_instance pi
                       LEFT JOIN grac_practice.record_status_master prs ON prs.record_status_id = pi.record_status_id
                      WHERE pi.practice_instance_id = @src_instance_id
                        AND (pi.status IN (N'Inactive', N'Retired') OR prs.status_code IN (N'Inactive', N'Retired')))
                THEN 0
            WHEN ISNULL(@total_dep_categories, 0) = 0                          THEN 0
            WHEN ISNULL(@resolved_dep_count, 0) >= ISNULL(@total_dep_categories, 0) THEN 1
            ELSE 0
        END;

        IF @is_operationalized = 0
            THROW 55145, 'sp_custom_gap_analysis_save: the related Practice has not been Operationalized yet; analysis is not allowed until it is.', 1;
    END

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

    DECLARE @current_state_code NVARCHAR(60);
    SELECT @current_state_code = s.state_code
      FROM grac_practice.custom_gap g
      LEFT JOIN grac_practice.gap_lifecycle_state_master s ON s.lifecycle_state_id = g.lifecycle_state_id
     WHERE g.custom_gap_id = @custom_gap_id;

    IF @current_state_code IS NULL SET @current_state_code = N'New';

    DECLARE @lifecycle_transitioned BIT = 0, @lifecycle_error NVARCHAR(4000) = NULL;
    IF @current_state_code IN (N'New', N'Validation', N'Analysis')
    BEGIN
        BEGIN TRY
            EXEC grac_practice.sp_custom_gap_lifecycle_transition
                @custom_gap_id       = @custom_gap_id,
                @action_code         = N'Delegate',
                @remark              = N'Auto-delegated after analysis save.',
                @caller_employee_id  = @analysed_by_employee_id,
                @caller_display_name = @caller_display_name;
            SET @lifecycle_transitioned = 1;
        END TRY
        BEGIN CATCH
            SET @lifecycle_error = ERROR_MESSAGE();
            PRINT CONCAT(N'sp_custom_gap_analysis_save: auto-delegate warning: ', @lifecycle_error);
        END CATCH
    END

    DECLARE @final_state_code NVARCHAR(60), @final_state_name NVARCHAR(120);
    SELECT @final_state_code = s.state_code, @final_state_name = s.state_name
      FROM grac_practice.custom_gap g
      LEFT JOIN grac_practice.gap_lifecycle_state_master s ON s.lifecycle_state_id = g.lifecycle_state_id
     WHERE g.custom_gap_id = @custom_gap_id;
    IF @final_state_code IS NULL SET @final_state_code = N'New';
    IF @final_state_name IS NULL SET @final_state_name = N'New';

    SELECT @custom_gap_id AS CustomGapId;

    SELECT
        @task_created      AS TaskCreated,      @task_error      AS TaskError,
        @exception_created AS ExceptionCreated, @exception_error AS ExceptionError,
        @risk_created      AS RiskCreated,      @risk_error      AS RiskError,
        @lifecycle_transitioned AS LifecycleTransitioned, @lifecycle_error AS LifecycleError,
        @final_state_code       AS LifecycleStateCode,    @final_state_name AS LifecycleStateName;
END
GO

PRINT '372 rollback complete. sp_custom_gap_linked_artefacts and sp_custom_gap_analysis_save restored to their pre-372 (317/367) bodies.';
GO
