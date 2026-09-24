-- =====================================================================
-- 367 ROLLBACK -- restores sp_practice_gap_sync_for_instance,
-- sp_custom_gap_analysis_save, and sp_custom_gap_header to their exact
-- pre-367 bodies (356's, 324's, and 325's respectively). No data is
-- reverted -- any practice_gap_obligation rows added for previously-
-- invisible Not Started obligations, or any 55144/55145 rejections that
-- already happened, are not undone; this only restores the procedures'
-- prior behaviour going forward.
-- SAFE TO RE-RUN. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    PRINT 'ABORT (367 rollback): schema grac_practice missing.';
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. sp_practice_gap_sync_for_instance -- restored to 356's exact body.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_practice_gap_sync_for_instance
    @practice_instance_id BIGINT,
    @actor                NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @practice_instance_id IS NULL
        THROW 52720, 'sp_practice_gap_sync_for_instance: practice_instance_id is required.', 1;

    DECLARE @organization_id BIGINT;
    SELECT @organization_id = organization_id
    FROM   grac_practice.practice_instance
    WHERE  practice_instance_id = @practice_instance_id;

    IF @organization_id IS NULL
        THROW 52721, 'sp_practice_gap_sync_for_instance: instance not found.', 1;

    -- Current gap-territory obligations for this instance. NULL status
    -- reads as "Not Started" per the 243 rule, but Not Started is NOT
    -- a gap on its own -- only explicit Not Implemented / Partially
    -- Implemented are.
    DECLARE @current TABLE (
        practice_instance_obligation_id BIGINT PRIMARY KEY,
        obligation_name                 NVARCHAR(500) NULL,
        obligation_type_code            NVARCHAR(60)  NULL,
        status_code                     NVARCHAR(60)  NOT NULL
    );

    INSERT INTO @current
        (practice_instance_obligation_id, obligation_name, obligation_type_code, status_code)
    SELECT pio.practice_instance_obligation_id,
           pio.obligation_name,
           pio.obligation_type_code,
           ims.status_code
    FROM   grac_practice.practice_instance_obligation pio
    JOIN   grac_practice.implementation_status_master ims
           ON ims.implementation_status_id = pio.implementation_status_id
    WHERE  pio.practice_instance_id = @practice_instance_id
      AND  pio.status               = N'Active'
      AND  ims.status_code IN (N'Not Implemented', N'Partially Implemented');

    -- 356: which practice_instance_obligation_id rows are genuinely NEW
    -- to the gap this call (captured via OUTPUT on the 3b INSERT below).
    -- Read AFTER the transaction commits to decide whether to fire the
    -- reopen step -- deliberately not "any obligation is still failing",
    -- only "a failure that was not there a moment ago just appeared".
    DECLARE @newly_added TABLE (practice_instance_obligation_id BIGINT PRIMARY KEY);

    BEGIN TRAN;

    -- Ensure the parent row exists. Insert only when there is at least
    -- one current gap-territory obligation -- do not create an empty
    -- Closed gap just because the instance had no obligations.
    IF NOT EXISTS (SELECT 1 FROM grac_practice.practice_gap
                    WHERE practice_instance_id = @practice_instance_id)
       AND EXISTS (SELECT 1 FROM @current)
    BEGIN
        INSERT grac_practice.practice_gap
            (organization_id, practice_instance_id, gap_status,
             opened_dt, entered_by)
        VALUES
            (@organization_id, @practice_instance_id, N'Open',
             SYSUTCDATETIME(), @actor);
    END

    DECLARE @practice_gap_id BIGINT;
    SELECT @practice_gap_id = practice_gap_id
    FROM   grac_practice.practice_gap
    WHERE  practice_instance_id = @practice_instance_id;

    -- 3a. Retire any active child whose obligation is no longer in gap
    --     territory. Cast covers "status moved to Implemented / N/A"
    --     AND "obligation was retired from the instance".
    IF @practice_gap_id IS NOT NULL
    BEGIN
        UPDATE pgo
           SET status     = N'Retired',
               removed_dt = SYSUTCDATETIME(),
               updated_by = @actor,
               updated_dt = SYSUTCDATETIME()
        FROM   grac_practice.practice_gap_obligation pgo
        WHERE  pgo.practice_gap_id = @practice_gap_id
          AND  pgo.status          = N'Active'
          AND  NOT EXISTS (SELECT 1 FROM @current c
                            WHERE c.practice_instance_obligation_id
                                = pgo.practice_instance_obligation_id);
    END

    -- 3b. Add active children for any current gap-territory obligation
    --     that has no active row yet. The partial unique index above
    --     already prevents duplicates; NOT EXISTS also skips the check
    --     when the row is there. 356: OUTPUT captures exactly which
    --     obligation ids this INSERT actually added, so the reopen step
    --     below can tell "a new failure just appeared" from "the same
    --     ones are still failing".
    IF @practice_gap_id IS NOT NULL
    BEGIN
        INSERT grac_practice.practice_gap_obligation
            (practice_gap_id, practice_instance_obligation_id,
             obligation_name, obligation_type_code,
             logged_status_code, status, entered_by)
        OUTPUT inserted.practice_instance_obligation_id INTO @newly_added
        SELECT @practice_gap_id, c.practice_instance_obligation_id,
               c.obligation_name, c.obligation_type_code,
               c.status_code, N'Active', @actor
        FROM   @current c
        WHERE  NOT EXISTS (SELECT 1 FROM grac_practice.practice_gap_obligation pgo
                            WHERE pgo.practice_gap_id = @practice_gap_id
                              AND pgo.practice_instance_obligation_id
                                  = c.practice_instance_obligation_id
                              AND pgo.status = N'Active');

        -- 3c. Recompute parent gap_status. Close when no actives remain,
        --     Open (with reopened_dt on transitions Closed -> Open) when
        --     any active row exists.
        DECLARE @active_count INT = (
            SELECT COUNT(*) FROM grac_practice.practice_gap_obligation
             WHERE practice_gap_id = @practice_gap_id
               AND status          = N'Active');

        IF @active_count = 0
        BEGIN
            UPDATE grac_practice.practice_gap
               SET gap_status = N'Closed',
                   closed_dt  = SYSUTCDATETIME(),
                   updated_by = @actor,
                   updated_dt = SYSUTCDATETIME()
             WHERE practice_gap_id = @practice_gap_id
               AND gap_status      = N'Open';
        END
        ELSE
        BEGIN
            UPDATE grac_practice.practice_gap
               SET gap_status  = N'Open',
                   -- Only stamp reopened_dt on an actual Closed -> Open
                   -- transition; the current UPDATE clause runs on both.
                   reopened_dt = CASE WHEN gap_status = N'Closed'
                                      THEN SYSUTCDATETIME()
                                      ELSE reopened_dt END,
                   closed_dt   = NULL,
                   updated_by  = @actor,
                   updated_dt  = SYSUTCDATETIME()
             WHERE practice_gap_id = @practice_gap_id;
        END
    END

    COMMIT TRAN;

    -- =================================================================
    -- 356: reopen an already-Analysed Gap Centre gap when a genuinely
    -- new Obligation failure was just added above. Runs after the
    -- practice_gap/practice_gap_obligation transaction has already
    -- committed, and is best-effort -- an Obligation save must never
    -- fail because this step could not run, exactly the same tolerance
    -- this proc's own caller (ResolveWorkspaceService.
    -- SyncGapForInstanceAsync) already applies to this whole procedure.
    -- =================================================================
    IF EXISTS (SELECT 1 FROM @newly_added)
    BEGIN
        DECLARE @gap_to_reopen_id BIGINT;
        SELECT TOP 1 @gap_to_reopen_id = cg.custom_gap_id
          FROM grac_practice.custom_gap cg
          JOIN grac_practice.gap_lifecycle_state_master s
               ON s.lifecycle_state_id = cg.lifecycle_state_id
         WHERE cg.source_reference_type = N'PracticeInstance'
           AND cg.source_reference_id   = @practice_instance_id
           AND cg.organization_id       = @organization_id
           AND s.state_code             = N'Delegated'
         ORDER BY cg.custom_gap_id DESC;

        IF @gap_to_reopen_id IS NOT NULL
        BEGIN
            DECLARE @reopen_remark NVARCHAR(MAX) = N'Auto-reopened: a new Obligation was logged '
                + N'Not Implemented / Partially Implemented under '
                + N'this Practice Instance after the gap had '
                + N'already been analysed.';
            BEGIN TRY
                EXEC grac_practice.sp_custom_gap_lifecycle_transition
                     @custom_gap_id       = @gap_to_reopen_id,
                     @action_code         = N'ReopenObligation',
                     @remark              = @reopen_remark,
                     @caller_employee_id  = NULL,
                     @caller_display_name = @actor;
            END TRY
            BEGIN CATCH
                PRINT CONCAT(N'sp_practice_gap_sync_for_instance: auto-reopen warning: ', ERROR_MESSAGE());
            END CATCH
        END
    END

    SELECT @practice_instance_id  AS PracticeInstanceId,
           @practice_gap_id       AS PracticeGapId,
           (SELECT gap_status FROM grac_practice.practice_gap
             WHERE practice_gap_id = @practice_gap_id) AS GapStatus,
           (SELECT COUNT(*) FROM grac_practice.practice_gap_obligation
             WHERE practice_gap_id = @practice_gap_id AND status = N'Active') AS ActiveObligationCount;
END
GO
PRINT '367 rollback: sp_practice_gap_sync_for_instance restored to 356''s body.';
GO

-- =====================================================================
-- 2. sp_custom_gap_analysis_save -- restored to 324's exact body.
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
PRINT '367 rollback: sp_custom_gap_analysis_save restored to 324''s body.';
GO

-- =====================================================================
-- 3. sp_custom_gap_header -- restored to 325's exact body.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_custom_gap_header
    @custom_gap_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF @custom_gap_id IS NULL
        THROW 55160, 'sp_custom_gap_header: custom_gap_id is required.', 1;

    SELECT
        g.custom_gap_id            AS CustomGapId,
        g.organization_id          AS OrganizationId,
        g.title                    AS Title,
        g.description              AS Description,
        g.status                   AS StatusCode,
        g.priority                 AS Priority,
        g.severity_code            AS SeverityCode,
        g.severity_name            AS SeverityName,
        g.detection_method_code    AS DetectionMethodCode,
        g.detection_method_name    AS DetectionMethodName,
        g.owner_display_name       AS OwnerName,
        g.owner_employee_id        AS OwnerEmployeeId,
        g.due_date                 AS DueDate,
        s.state_code               AS LifecycleStateCode,
        s.state_name               AS LifecycleStateName,
        s.is_terminal               AS LifecycleIsTerminal,
        s.is_valid_terminal        AS LifecycleIsValidTerminal,
        g.gap_source_module_code   AS SourceModuleCode,
        g.duplicate_of_gap_id      AS DuplicateOfGapId,
        p.title                    AS DuplicateOfGapTitle,
        g.invalid_reason           AS InvalidReason,
        g.sla_master_id            AS SlaMasterId,
        g.sla_master_name          AS SlaMasterName,
        g.sla_days_effective       AS SlaDaysEffective,
        g.sla_source_code          AS SlaSourceCode,
        CAST(CASE WHEN EXISTS (
                SELECT 1 FROM grac_practice.exception_request er
                WHERE er.custom_gap_id     = g.custom_gap_id
                  AND er.request_type_code = N'SLA_CANDIDATE'
                  AND er.status_code       = N'Pending')
             THEN 1 ELSE 0 END AS BIT)  AS SlaOverridePending,
        pi.practice_instance_id    AS PracticeInstanceId,
        pi.instance_code           AS PracticeInstanceCode,
        pi.instance_name           AS PracticeInstanceName,
        g.entered_dt                AS IdentifiedDate
      FROM grac_practice.custom_gap g
 LEFT JOIN grac_practice.gap_lifecycle_state_master s ON s.lifecycle_state_id = g.lifecycle_state_id
 LEFT JOIN grac_practice.custom_gap p                 ON p.custom_gap_id      = g.duplicate_of_gap_id
 LEFT JOIN grac_practice.practice_instance pi          ON pi.practice_instance_id = g.source_reference_id
                                                       AND g.source_reference_type = N'PracticeInstance'
                                                       AND pi.organization_id      = g.organization_id
     WHERE g.custom_gap_id = @custom_gap_id;
END
GO
PRINT '367 rollback: sp_custom_gap_header restored to 325''s body.';
GO

-- =====================================================================
-- Verification
-- =====================================================================
PRINT '=== 367 rollback verification ===';

SELECT '367-rollback-a sync proc restored (no @gap_trigger table)' AS Check_,
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_practice_gap_sync_for_instance','P')) NOT LIKE '%@gap_trigger%'
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '367-rollback-b analysis_save restored (no 55144/55145 guards)',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_custom_gap_analysis_save','P')) NOT LIKE '%55144%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_custom_gap_analysis_save','P')) NOT LIKE '%55145%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '367-rollback-c header proc restored (no IsPracticeOperationalized)',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_custom_gap_header','P')) NOT LIKE '%IsPracticeOperationalized%'
            THEN 'PASS' ELSE 'FAIL' END;

PRINT '';
PRINT '367 rollback complete. All three procedures are back to their pre-367 bodies.';
GO

SET NOEXEC OFF;
GO
