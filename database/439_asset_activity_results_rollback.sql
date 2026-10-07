-- =====================================================================
-- 439 rollback -- Asset activity results, dispositions, evidence expiry
--                 and restrictive-use reviews
--
--   * drops the 439 procedures (results, dispositions, reviews, readers);
--   * restores the 438 bodies verbatim: fn_asset_activity_settings,
--     sp_asset_activity_task_sync, sp_asset_activity_schedule_sync,
--     sp_asset_activity_generate, sp_asset_activity_run,
--     fn_asset_stored_values, sp_asset_notification_parties,
--     sp_asset_notification_sweep, sp_asset_activity_config_get,
--     sp_asset_activity_setting_save, sp_asset_activity_schedules,
--     sp_asset_activity_occurrences;
--   * drops the result, disposition, evidence-field and review tables and
--     the 439 columns; Waived occurrences become Cancelled (the 438
--     vocabulary); the notification object vocabulary goes back WITH
--     NOCHECK (evidence notification history stays); the Evidence expiry
--     activity is flagged as having no source again.
-- Approved results already written to the register (last date, certificate,
-- expiry) stay. practice_audit_trace rows stay as history. Deploy the API /
-- Web without the 439 changes first. Re-runnable. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOEXEC OFF;
GO

DROP PROCEDURE IF EXISTS grac_practice.sp_asset_restrictive_reviews;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_activity_occurrence_get;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_restrictive_review_decide;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_activity_disposition_decide;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_activity_disposition_request;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_activity_disposition_apply;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_activity_result_decide;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_activity_result_save;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_activity_result_apply;
DROP PROCEDURE IF EXISTS grac_practice.sp_asset_restrictive_review_sync;
PRINT '439 rollback: 439 procedures dropped.';
GO

-- 438 body (verbatim).
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_activity_run
    @organization_id BIGINT,
    @actor           NVARCHAR(100) = N'scheduler',
    @tasks           INT           = NULL OUTPUT,
    @opened          INT           = NULL OUTPUT,
    @completed       INT           = NULL OUTPUT,
    @errors          INT           = NULL OUTPUT,
    @error_text      NVARCHAR(MAX) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT OFF;
    SELECT @tasks = 0, @opened = 0, @completed = 0, @errors = 0, @error_text = NULL;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 54650, 'Organization not found.', 1;
    EXEC grac_practice.sp_asset_activity_task_sync @organization_id = @organization_id, @actor = @actor, @completed = @completed OUTPUT;
    EXEC grac_practice.sp_asset_activity_schedule_sync @organization_id = @organization_id;
    EXEC grac_practice.sp_asset_activity_generate @organization_id = @organization_id, @actor = @actor,
         @opened = @opened OUTPUT, @tasks = @tasks OUTPUT, @errors = @errors OUTPUT, @error_text = @error_text OUTPUT;
END
GO
PRINT '439 rollback: sp_asset_activity_run restored.';
GO

-- 438 body (verbatim).
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_activity_generate
    @organization_id BIGINT,
    @actor           NVARCHAR(100) = N'scheduler',
    @opened          INT           = NULL OUTPUT,
    @tasks           INT           = NULL OUTPUT,
    @errors          INT           = NULL OUTPUT,
    @error_text      NVARCHAR(MAX) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT OFF;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'scheduler');
    SELECT @opened = 0, @tasks = 0, @errors = 0, @error_text = NULL;
    DECLARE @today DATE = CAST(SYSUTCDATETIME() AS DATE);

    -- a. Reconciliation flags (a reason already reconciled is not raised again).
    UPDATE o
       SET needs_reconciliation = 1, reconciliation_reason = r.reason, updated_by = @actor, updated_dt = SYSUTCDATETIME()
      FROM grac_practice.asset_activity_occurrence o
      LEFT JOIN grac_practice.asset_activity_schedule s ON s.asset_id = o.asset_id AND s.template_code = o.template_code
     CROSS APPLY (SELECT CASE
               WHEN s.schedule_state IS NULL OR s.schedule_state <> N'SCHEDULED'
                   THEN N'The activity no longer applies or is no longer scheduled for this asset.'
               WHEN s.status_code = N'COVERED'
                   THEN N'A contract now covers this renewal; complete or cancel the task after reconciling (BRD 7.1.5).'
               WHEN s.next_due_date <> o.due_date
                   THEN CONCAT(N'The due date is now ', CONVERT(NVARCHAR(10), s.next_due_date, 23), N'.') END AS reason) r
     WHERE o.organization_id = @organization_id AND o.status = N'OPEN' AND o.needs_reconciliation = 0
       AND r.reason IS NOT NULL AND r.reason <> ISNULL(o.reconciliation_reason, N'');

    -- b. Coverage no longer reaches a covered renewal: it becomes an asset task.
    UPDATE o
       SET status = N'OPEN', decision = N'ASSET_TASK',
           decision_reason = N'The matching contract no longer covers the asset through the due date (BRD 7.1.3).',
           contract_version_id = NULL, updated_by = @actor, updated_dt = SYSUTCDATETIME()
      FROM grac_practice.asset_activity_occurrence o
      JOIN grac_practice.asset_activity_schedule s ON s.asset_id = o.asset_id AND s.template_code = o.template_code
     WHERE o.organization_id = @organization_id AND o.status = N'COVERED' AND s.schedule_state = N'SCHEDULED'
       AND s.next_due_date = o.due_date AND s.status_code <> N'COVERED'
       AND DATEADD(DAY, -(SELECT LeadDays FROM grac_practice.fn_asset_activity_settings(@organization_id) x
                           WHERE x.TemplateCode = o.template_code), o.due_date) <= @today
       AND NOT EXISTS (SELECT 1 FROM grac_practice.asset_activity_occurrence z
                        WHERE z.asset_id = o.asset_id AND z.template_code = o.template_code AND z.status = N'OPEN');

    -- c. New occurrences.
    DECLARE @new TABLE (occurrence_id BIGINT NOT NULL);
    INSERT grac_practice.asset_activity_occurrence
        (organization_id, asset_id, template_code, due_date, sequence_no, occurrence_key, decision, decision_reason,
         contract_version_id, status, entered_by)
    OUTPUT inserted.occurrence_id INTO @new (occurrence_id)
    SELECT @organization_id, s.asset_id, s.template_code, s.next_due_date, q.seq,
           CONCAT(N'AA-', s.template_code, N'-', s.asset_id, N'-', CONVERT(NVARCHAR(8), s.next_due_date, 112), N'-', q.seq),
           CASE WHEN s.status_code = N'COVERED' THEN N'CONTRACT_COVERED' ELSE N'ASSET_TASK' END,
           CASE WHEN s.status_code = N'COVERED'
                    THEN N'A matching contract covers the asset through the due date: contract-level renewal, no separate task (BRD 7.1.3).'
                WHEN t.activity_kind = N'EXECUTION' AND s.contract_version_id IS NOT NULL
                    THEN N'Asset-specific result: one task per asset; the covering contract is linked (BRD 7.1.2).'
                WHEN t.activity_kind = N'EXECUTION' THEN N'Asset-specific result: one task per asset (BRD 7.1.4).'
                ELSE N'No matching contract covers the asset: individual renewal task (BRD 7.1.3).' END
           + CASE WHEN q.seq > 1 THEN N' The previous task for this due date was cancelled.' ELSE N'' END,
           s.contract_version_id,
           CASE WHEN s.status_code = N'COVERED' THEN N'COVERED' ELSE N'OPEN' END, @actor
      FROM grac_practice.asset_activity_schedule s
      JOIN grac_practice.asset_activity_template t ON t.template_code = s.template_code
      JOIN grac_practice.fn_asset_activity_settings(@organization_id) st ON st.TemplateCode = s.template_code AND st.IsActive = 1
     CROSS APPLY (SELECT 1 + COUNT(*) AS seq FROM grac_practice.asset_activity_occurrence z
                   WHERE z.asset_id = s.asset_id AND z.template_code = s.template_code AND z.due_date = s.next_due_date) q
     WHERE s.organization_id = @organization_id AND s.schedule_state = N'SCHEDULED'
       AND DATEADD(DAY, -st.LeadDays, s.next_due_date) <= @today
       AND NOT EXISTS (SELECT 1 FROM grac_practice.asset_activity_occurrence z
                        WHERE z.asset_id = s.asset_id AND z.template_code = s.template_code
                          AND (z.status = N'OPEN' OR (z.due_date = s.next_due_date AND z.status IN (N'COMPLETED', N'COVERED'))));
    SET @opened = @@ROWCOUNT;
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    SELECT N'asset-activity-occurrence', o.occurrence_id, N'CREATE', NULL,
           (SELECT o.occurrence_key AS occurrenceKey, o.asset_id AS assetId, o.template_code AS templateCode, o.due_date AS dueDate,
                   o.decision AS decision, o.contract_version_id AS contractVersionId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
           N'Active', @actor
      FROM @new n JOIN grac_practice.asset_activity_occurrence o ON o.occurrence_id = n.occurrence_id;

    -- d. Tasks.
    DECLARE @occ BIGINT, @asset BIGINT, @tpl NVARCHAR(40), @due DATE, @key NVARCHAR(200), @ver BIGINT,
            @tpl_name NVARCHAR(160), @owner_key NVARCHAR(100), @grouping NVARCHAR(12), @cmp_owner BIGINT,
            @asset_name NVARCHAR(400), @asset_owner BIGINT, @crit NVARCHAR(40), @reason NVARCHAR(400),
            @assignee BIGINT, @prio NVARCHAR(30), @title NVARCHAR(250), @descr NVARCHAR(MAX), @ref NVARCHAR(200),
            @cmp BIGINT, @cmp_key NVARCHAR(120), @period CHAR(6), @tid BIGINT, @contract_text NVARCHAR(400), @target DATETIME2;
    DECLARE task_cur CURSOR LOCAL STATIC FOR
        SELECT o.occurrence_id, o.asset_id, o.template_code, o.due_date, o.occurrence_key, o.contract_version_id, o.decision_reason,
               t.template_name, t.owner_field_key, st.GroupingMode, st.CampaignOwnerEmployeeId,
               a.asset_name, a.owner_id, c.criticality_code
          FROM grac_practice.asset_activity_occurrence o
          JOIN grac_practice.asset_activity_template t ON t.template_code = o.template_code
          JOIN grac_practice.fn_asset_activity_settings(@organization_id) st ON st.TemplateCode = o.template_code
          JOIN grac_practice.organization_dependency_asset a ON a.asset_id = o.asset_id
          LEFT JOIN grac_practice.criticality_master c ON c.criticality_id = a.criticality_id
         WHERE o.organization_id = @organization_id AND o.status = N'OPEN' AND o.decision = N'ASSET_TASK' AND o.task_id IS NULL
         ORDER BY o.due_date, o.occurrence_id;
    OPEN task_cur;
    FETCH NEXT FROM task_cur INTO @occ, @asset, @tpl, @due, @key, @ver, @reason, @tpl_name, @owner_key, @grouping, @cmp_owner,
                                  @asset_name, @asset_owner, @crit;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            SELECT @assignee = NULL, @cmp = NULL, @cmp_key = NULL, @tid = NULL, @contract_text = NULL;
            -- Owner: the template owner field (a person), else the asset owner (D65).
            IF @owner_key IS NOT NULL
                SET @assignee = grac_practice.fn_asset_activity_person(@organization_id,
                    (SELECT LEFT(v.value_text, 100) FROM grac_practice.asset_field_value v
                       JOIN grac_practice.asset_field_definition f ON f.field_definition_id = v.field_definition_id AND f.field_key = @owner_key
                      WHERE v.asset_id = @asset));
            IF @assignee IS NULL
                SET @assignee = grac_practice.fn_asset_activity_person(@organization_id, CAST(@asset_owner AS NVARCHAR(30)));
            SET @prio = CASE @crit WHEN N'Critical' THEN N'Critical' WHEN N'High' THEN N'High' WHEN N'Low' THEN N'Low' ELSE N'Medium' END;
            IF @ver IS NOT NULL
                SELECT @contract_text = CONCAT(c.contract_number, N' version ', v.version_no, N' (', c.contract_name, N')')
                  FROM grac_practice.asset_contract_version v
                  JOIN grac_practice.asset_contract c ON c.contract_id = v.contract_id
                 WHERE v.version_id = @ver;

            IF @grouping = N'CAMPAIGN'
            BEGIN
                SET @period = CONVERT(CHAR(6), @due, 112);
                SET @cmp_key = CONCAT(N'AC-', @tpl, N'-', @period);
                SELECT @cmp = campaign_id FROM grac_practice.asset_activity_campaign
                 WHERE organization_id = @organization_id AND campaign_key = @cmp_key;
                IF @cmp IS NULL
                BEGIN
                    INSERT grac_practice.asset_activity_campaign
                        (organization_id, template_code, period_key, campaign_key, campaign_name, owner_employee_id, entered_by)
                    VALUES (@organization_id, @tpl, @period, @cmp_key,
                            CONCAT(@tpl_name, N' campaign ', LEFT(@period, 4), N'-', RIGHT(@period, 2)), @cmp_owner, @actor);
                    SET @cmp = SCOPE_IDENTITY();
                END
            END

            SET @title = LEFT(CONCAT(@tpl_name, N' - ', @asset_name, N' (due ', CONVERT(NVARCHAR(10), @due, 23), N')'), 250);
            SET @descr = CONCAT(@tpl_name, N' of ', @asset_name, N', due ', CONVERT(NVARCHAR(10), @due, 23), N'.', CHAR(13), CHAR(10),
                                N'Occurrence: ', @key, CHAR(13), CHAR(10),
                                CASE WHEN @cmp_key IS NULL THEN N'' ELSE CONCAT(N'Campaign: ', @cmp_key, CHAR(13), CHAR(10)) END,
                                CASE WHEN @contract_text IS NULL THEN N'' ELSE CONCAT(N'Contract: ', @contract_text, CHAR(13), CHAR(10)) END,
                                @reason);
            SET @ref = ISNULL(@cmp_key, @key);
            SET @target = CAST(@due AS DATETIME2);
            EXEC grac_practice.sp_task_open
                 @organization_id         = @organization_id,
                 @task_type_code          = N'AssetActivity',
                 @subject_entity_type     = N'AssetActivityOccurrence',
                 @subject_entity_id       = @occ,
                 @subject_title           = @title,
                 @subject_description     = @descr,
                 @priority                = @prio,
                 @criticality             = @crit,
                 @origin_code             = N'GRAC',
                 @assigned_to_employee_id = @assignee,
                 @target_date             = @target,
                 @source_type_code        = N'Asset',
                 @source_record_id        = @occ,
                 @source_reference        = @ref,
                 @resolve_owner           = 0,
                 @task_id                 = @tid OUTPUT;
            UPDATE grac_practice.asset_activity_occurrence
               SET task_id = @tid, campaign_id = @cmp, task_error = NULL, updated_by = @actor, updated_dt = SYSUTCDATETIME()
             WHERE occurrence_id = @occ;
            SET @tasks = @tasks + 1;
        END TRY
        BEGIN CATCH
            IF XACT_STATE() <> 0 ROLLBACK;
            SET @errors = @errors + 1;
            SET @error_text = LEFT(CONCAT(@error_text, CASE WHEN @error_text IS NULL THEN N'' ELSE CHAR(10) END,
                                          N'Activity occurrence ', @occ, N': ', ERROR_MESSAGE()), 4000);
            UPDATE grac_practice.asset_activity_occurrence
               SET task_error = LEFT(ERROR_MESSAGE(), 1000), updated_by = @actor, updated_dt = SYSUTCDATETIME()
             WHERE occurrence_id = @occ;
        END CATCH
        FETCH NEXT FROM task_cur INTO @occ, @asset, @tpl, @due, @key, @ver, @reason, @tpl_name, @owner_key, @grouping, @cmp_owner,
                                      @asset_name, @asset_owner, @crit;
    END
    CLOSE task_cur;
    DEALLOCATE task_cur;
END
GO
PRINT '439 rollback: sp_asset_activity_generate restored.';
GO

-- 438 body (verbatim).
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_activity_task_sync
    @organization_id BIGINT,
    @actor           NVARCHAR(100) = N'scheduler',
    @completed       INT           = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'scheduler');
    SET @completed = 0;
    DECLARE @done TABLE (occurrence_id BIGINT NOT NULL, asset_id BIGINT NOT NULL, template_code NVARCHAR(40) NOT NULL,
                         status NVARCHAR(12) NOT NULL, completed_dt DATETIME2 NULL);
    BEGIN TRAN;
    UPDATE o
       SET status = CASE WHEN s.status_code = N'Cancelled' THEN N'CANCELLED' ELSE N'COMPLETED' END,
           completed_dt = CASE WHEN s.status_code = N'Cancelled' THEN NULL ELSE COALESCE(t.completed_dt, t.closed_at, SYSUTCDATETIME()) END,
           completed_by_employee_id = CASE WHEN s.status_code = N'Cancelled' THEN NULL ELSE t.completed_by_employee_id END,
           closed_dt = SYSUTCDATETIME(), updated_by = @actor, updated_dt = SYSUTCDATETIME()
    OUTPUT inserted.occurrence_id, inserted.asset_id, inserted.template_code, inserted.status, inserted.completed_dt
      INTO @done (occurrence_id, asset_id, template_code, status, completed_dt)
      FROM grac_practice.asset_activity_occurrence o
      JOIN grac_practice.practice_task t ON t.task_id = o.task_id
      JOIN grac_practice.entity_status_master s ON s.entity_status_id = t.current_status_id
     WHERE o.organization_id = @organization_id AND o.status = N'OPEN'
       AND (s.status_code IN (N'Closed', N'Cancelled') OR t.completed_dt IS NOT NULL);
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    SELECT N'asset-activity-occurrence', d.occurrence_id, d.status, N'{"status":"OPEN"}',
           (SELECT d.status AS status, d.completed_dt AS completedDt FOR JSON PATH, WITHOUT_ARRAY_WRAPPER), N'Active', @actor
      FROM @done d;
    COMMIT;
    SET @completed = (SELECT COUNT(*) FROM @done WHERE status = N'COMPLETED');

    -- The last date field follows the completion (never moves back).
    DECLARE @asset BIGINT, @key NVARCHAR(100), @dt DATE, @cur DATE, @val NVARCHAR(400);
    DECLARE last_cur CURSOR LOCAL STATIC FOR
        SELECT d.asset_id, t.last_date_field_key, CAST(d.completed_dt AS DATE)
          FROM @done d
          JOIN grac_practice.asset_activity_template t ON t.template_code = d.template_code
         WHERE d.status = N'COMPLETED' AND t.last_date_field_key IS NOT NULL;
    OPEN last_cur;
    FETCH NEXT FROM last_cur INTO @asset, @key, @dt;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @cur = (SELECT v.value_date FROM grac_practice.asset_field_value v
                      JOIN grac_practice.asset_field_definition f ON f.field_definition_id = v.field_definition_id AND f.field_key = @key
                     WHERE v.asset_id = @asset);
        IF @cur IS NULL OR @cur < @dt
        BEGIN
            SET @val = CONVERT(NVARCHAR(10), @dt, 23);
            EXEC grac_practice.sp_asset_field_value_set @asset_id = @asset, @field_key = @key, @value = @val, @actor = @actor;
        END
        FETCH NEXT FROM last_cur INTO @asset, @key, @dt;
    END
    CLOSE last_cur;
    DEALLOCATE last_cur;
END
GO
PRINT '439 rollback: sp_asset_activity_task_sync restored.';
GO

-- 438 body (verbatim).
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_activity_schedule_sync
    @organization_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @today DATE = CAST(SYSUTCDATETIME() AS DATE);

    CREATE TABLE #cov (asset_id BIGINT NOT NULL, coverage_type NVARCHAR(160) NOT NULL, version_id BIGINT NOT NULL, eff_end DATE NULL);
    INSERT #cov (asset_id, coverage_type, version_id, eff_end)
    SELECT AssetId, CoverageType, VersionId, EffectiveEnd
      FROM grac_practice.fn_asset_coverage_line_view(@organization_id)
     WHERE LineStatus IN (N'COVERED', N'EXPIRING');

    CREATE TABLE #in (
        asset_id BIGINT NOT NULL, template_code NVARCHAR(40) NOT NULL, activity_kind NVARCHAR(12) NOT NULL,
        due_soon_days INT NOT NULL, coverage_types NVARCHAR(200) NULL,
        required_val NVARCHAR(400) NULL, frequency_text NVARCHAR(400) NULL, basis NVARCHAR(400) NULL,
        field_last DATE NULL, expiry DATE NULL, occ_due DATE NULL, occ_done DATE NULL, open_due DATE NULL,
        PRIMARY KEY (asset_id, template_code));
    INSERT #in (asset_id, template_code, activity_kind, due_soon_days, coverage_types, required_val, frequency_text, basis,
                field_last, expiry, occ_due, occ_done, open_due)
    SELECT a.asset_id, t.template_code, t.activity_kind, st.DueSoonDays, t.coverage_types,
           (SELECT v.value_text FROM grac_practice.asset_field_value v
              JOIN grac_practice.asset_field_definition f ON f.field_definition_id = v.field_definition_id AND f.field_key = t.required_field_key
             WHERE v.asset_id = a.asset_id),
           (SELECT v.value_text FROM grac_practice.asset_field_value v
              JOIN grac_practice.asset_field_definition f ON f.field_definition_id = v.field_definition_id AND f.field_key = t.frequency_field_key
             WHERE v.asset_id = a.asset_id),
           (SELECT v.value_text FROM grac_practice.asset_field_value v
              JOIN grac_practice.asset_field_definition f ON f.field_definition_id = v.field_definition_id AND f.field_key = t.basis_field_key
             WHERE v.asset_id = a.asset_id),
           (SELECT v.value_date FROM grac_practice.asset_field_value v
              JOIN grac_practice.asset_field_definition f ON f.field_definition_id = v.field_definition_id AND f.field_key = t.last_date_field_key
             WHERE v.asset_id = a.asset_id),
           (SELECT v.value_date FROM grac_practice.asset_field_value v
              JOIN grac_practice.asset_field_definition f ON f.field_definition_id = v.field_definition_id AND f.field_key = t.expiry_field_key
             WHERE v.asset_id = a.asset_id),
           lo.due_date, CAST(lo.completed_dt AS DATE),
           (SELECT o.due_date FROM grac_practice.asset_activity_occurrence o
             WHERE o.asset_id = a.asset_id AND o.template_code = t.template_code AND o.status = N'OPEN')
      FROM grac_practice.organization_dependency_asset a
      LEFT JOIN grac_practice.entity_status_master s ON s.entity_status_id = a.current_status_id
     CROSS JOIN grac_practice.asset_activity_template t
      JOIN grac_practice.fn_asset_activity_settings(@organization_id) st ON st.TemplateCode = t.template_code AND st.IsActive = 1
     OUTER APPLY (SELECT TOP 1 o.due_date, o.completed_dt
                    FROM grac_practice.asset_activity_occurrence o
                   WHERE o.asset_id = a.asset_id AND o.template_code = t.template_code AND o.status = N'COMPLETED'
                   ORDER BY o.due_date DESC, o.occurrence_id DESC) lo
     WHERE a.organization_id = @organization_id
       AND ISNULL(s.status_code, N'ACTIVE') NOT IN (N'DRAFT', N'REQUESTED', N'APPROVED', N'ORDERED', N'LOST', N'STOLEN',
                                                     N'DISPOSED', N'ARCHIVED');

    CREATE TABLE #out (
        asset_id BIGINT NOT NULL, template_code NVARCHAR(40) NOT NULL, schedule_state NVARCHAR(16) NOT NULL,
        not_scheduled_reason NVARCHAR(300) NULL, frequency_text NVARCHAR(100) NULL, interval_value INT NULL, interval_unit NVARCHAR(10) NULL,
        basis NVARCHAR(40) NULL, last_done_date DATE NULL, next_due_date DATE NULL, due_source NVARCHAR(30) NULL,
        status_code NVARCHAR(16) NOT NULL, contract_version_id BIGINT NULL, coverage_end DATE NULL);
    INSERT #out (asset_id, template_code, schedule_state, not_scheduled_reason, frequency_text, interval_value, interval_unit, basis,
                 last_done_date, next_due_date, due_source, status_code, contract_version_id, coverage_end)
    SELECT i.asset_id, i.template_code, z.state, z.reason, LEFT(i.frequency_text, 100), iv.IntervalValue, iv.IntervalUnit,
           LEFT(i.basis, 40), CASE WHEN z.state = N'SCHEDULED' THEN n.last_done END,
           CASE WHEN z.state = N'SCHEDULED' THEN n.next_due END,
           CASE WHEN z.state = N'SCHEDULED' THEN n.source END,
           CASE WHEN z.state = N'NOT_APPLICABLE' THEN N'NOT_APPLICABLE'
                WHEN z.state = N'NOT_SCHEDULED' THEN N'NOT_SCHEDULED'
                WHEN i.activity_kind = N'RENEWAL' AND cv.version_id IS NOT NULL
                     AND ISNULL(cv.eff_end, CAST('9999-12-31' AS DATE)) >= n.next_due THEN N'COVERED'
                WHEN n.next_due < @today THEN N'OVERDUE'
                WHEN n.next_due <= DATEADD(DAY, i.due_soon_days, @today) THEN N'DUE_SOON'
                ELSE N'VALID' END,
           cv.version_id, cv.eff_end
      FROM #in i
     OUTER APPLY grac_practice.fn_asset_activity_interval(i.frequency_text) iv
     CROSS APPLY (SELECT CASE WHEN UPPER(LTRIM(RTRIM(ISNULL(i.basis, N'')))) IN (N'APPROVED_COMPLETION_DATE', N'COMPLETION_DATE') THEN N'COMPLETION'
                              WHEN UPPER(LTRIM(RTRIM(ISNULL(i.basis, N'')))) IN (N'USAGE', N'RUN_HOURS', N'MANUFACTURER') THEN N'UNSUPPORTED'
                              ELSE N'SCHEDULED' END AS basis_class) b
     CROSS APPLY (SELECT
            CASE WHEN i.activity_kind = N'RENEWAL' THEN i.expiry
                 WHEN i.occ_done IS NOT NULL AND (i.field_last IS NULL OR i.occ_done >= i.field_last)
                     THEN grac_practice.fn_asset_activity_add(CASE WHEN b.basis_class = N'COMPLETION' THEN i.occ_done ELSE i.occ_due END,
                                                              iv.IntervalValue, iv.IntervalUnit)
                 WHEN i.field_last IS NOT NULL THEN grac_practice.fn_asset_activity_add(i.field_last, iv.IntervalValue, iv.IntervalUnit)
                 ELSE ISNULL(i.open_due, @today) END AS next_due,      -- no history: due now (D61), kept while it is open
            CASE WHEN i.activity_kind = N'RENEWAL' THEN NULL
                 WHEN i.occ_done IS NOT NULL AND (i.field_last IS NULL OR i.occ_done >= i.field_last) THEN i.occ_done
                 ELSE i.field_last END AS last_done,
            CASE WHEN i.activity_kind = N'RENEWAL' THEN N'EXPIRY_FIELD'
                 WHEN i.occ_done IS NOT NULL AND (i.field_last IS NULL OR i.occ_done >= i.field_last) THEN N'COMPLETED_OCCURRENCE'
                 WHEN i.field_last IS NOT NULL THEN N'LAST_DATE_FIELD'
                 ELSE N'NO_HISTORY' END AS source) n
     CROSS APPLY (SELECT
            CASE WHEN ISNULL(i.required_val, N'') <> N'Yes' THEN N'NOT_APPLICABLE'
                 WHEN i.activity_kind = N'RENEWAL' AND i.expiry IS NULL THEN N'NOT_SCHEDULED'
                 WHEN i.activity_kind = N'EXECUTION' AND iv.IntervalValue IS NULL THEN N'NOT_SCHEDULED'
                 WHEN i.activity_kind = N'EXECUTION' AND b.basis_class = N'UNSUPPORTED' THEN N'NOT_SCHEDULED'
                 ELSE N'SCHEDULED' END AS state,
            CASE WHEN ISNULL(i.required_val, N'') <> N'Yes' THEN NULL
                 WHEN i.activity_kind = N'RENEWAL' AND i.expiry IS NULL THEN N'No expiry date is recorded on the asset.'
                 WHEN i.activity_kind = N'EXECUTION' AND iv.IntervalValue IS NULL
                     THEN N'The frequency is missing or not understood (for example "12 months").'
                 WHEN i.activity_kind = N'EXECUTION' AND b.basis_class = N'UNSUPPORTED'
                     THEN CONCAT(N'The ', LOWER(REPLACE(i.basis, N'_', N' ')), N' basis needs meter readings; it is not scheduled yet.') END AS reason) z
     OUTER APPLY (SELECT TOP 1 c.version_id, c.eff_end
                    FROM #cov c
                   WHERE c.asset_id = i.asset_id AND i.coverage_types IS NOT NULL
                     AND CHARINDEX(N',' + c.coverage_type + N',', N',' + i.coverage_types + N',') > 0
                   ORDER BY ISNULL(c.eff_end, CAST('9999-12-31' AS DATE)) DESC, c.version_id DESC) cv;

    BEGIN TRAN;
    DELETE grac_practice.asset_activity_schedule WHERE organization_id = @organization_id;
    INSERT grac_practice.asset_activity_schedule
        (organization_id, asset_id, template_code, schedule_state, not_scheduled_reason, frequency_text, interval_value, interval_unit,
         basis, last_done_date, next_due_date, due_source, status_code, contract_version_id, coverage_end)
    SELECT @organization_id, asset_id, template_code, schedule_state, not_scheduled_reason, frequency_text, interval_value, interval_unit,
           basis, last_done_date, next_due_date, due_source, status_code, contract_version_id, coverage_end
      FROM #out;
    COMMIT;
END
GO
PRINT '439 rollback: sp_asset_activity_schedule_sync restored.';
GO

-- 438 body (verbatim).
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_notification_sweep
    @organization_id BIGINT,
    @actor           NVARCHAR(100) = N'scheduler',
    @opened          INT           = NULL OUTPUT,
    @closed          INT           = NULL OUTPUT,
    @queued          INT           = NULL OUTPUT,
    @errors          INT           = NULL OUTPUT,
    @error_text      NVARCHAR(MAX) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT OFF;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'scheduler');
    SELECT @opened = 0, @closed = 0, @queued = 0, @errors = 0, @error_text = NULL;
    DECLARE @org BIGINT = @organization_id;
    DECLARE @today DATE = CAST(SYSUTCDATETIME() AS DATE);

    CREATE TABLE #due (
        occurrence_key NVARCHAR(200) NOT NULL PRIMARY KEY,
        activity_code  NVARCHAR(40)  NOT NULL,
        object_type    NVARCHAR(30)  NOT NULL,
        object_id      BIGINT        NOT NULL,
        ref_id         BIGINT        NULL,
        asset_id       BIGINT        NULL,
        contract_id    BIGINT        NULL,
        trigger_date   DATE          NOT NULL,
        object_ref     NVARCHAR(200) NULL,
        object_title   NVARCHAR(400) NULL,
        severity_code  NVARCHAR(10)  NOT NULL
    );

    -- Contract renewal (9.1.5): earliest of notice, decision and end date of
    -- the version in force; stops once a renewal of that version completes.
    INSERT #due (occurrence_key, activity_code, object_type, object_id, ref_id, asset_id, contract_id, trigger_date,
                 object_ref, object_title, severity_code)
    SELECT CONCAT(x.act, N':CV:', cv.version_id, N':', CONVERT(NVARCHAR(8), t.d, 112)), x.act, N'CONTRACT_VERSION', cv.version_id,
           NULL, NULL, c.contract_id, t.d, c.contract_number, CONCAT(c.contract_name, N' (version ', cv.version_no, N')'),
           grac_practice.fn_asset_ntf_version_severity(cv.version_id)
      FROM grac_practice.asset_contract c
      JOIN grac_practice.asset_contract_version cv ON cv.version_id = c.current_version_id
     CROSS APPLY (SELECT MIN(v.d) AS d FROM (VALUES (cv.notice_date), (cv.decision_date), (cv.effective_end)) v(d)) t
     CROSS APPLY (SELECT grac_practice.fn_asset_ntf_contract_activity(c.contract_type) AS act) x
     WHERE c.organization_id = @org AND c.contract_status IN (N'ACTIVE', N'APPROVED', N'EXPIRED')
       AND cv.version_type <> N'TERMINATION' AND t.d IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM grac_practice.asset_contract_renewal r
                         JOIN grac_practice.entity_status_master s ON s.entity_status_id = r.current_status_id
                        WHERE r.prior_version_id = cv.version_id AND s.status_code = N'COMPLETED');

    -- Contract expiry (9.1.5): the version in force expired without a successor.
    INSERT #due (occurrence_key, activity_code, object_type, object_id, ref_id, asset_id, contract_id, trigger_date,
                 object_ref, object_title, severity_code)
    SELECT CONCAT(N'CONTRACT_EXPIRY:CV:', cv.version_id, N':', CONVERT(NVARCHAR(8), DATEADD(DAY, 1, cv.effective_end), 112)),
           N'CONTRACT_EXPIRY', N'CONTRACT_VERSION', cv.version_id, NULL, NULL, c.contract_id, DATEADD(DAY, 1, cv.effective_end),
           c.contract_number, CONCAT(c.contract_name, N' (version ', cv.version_no, N') expired'),
           grac_practice.fn_asset_ntf_version_severity(cv.version_id)
      FROM grac_practice.asset_contract c
      JOIN grac_practice.asset_contract_version cv ON cv.version_id = c.current_version_id
      JOIN grac_practice.entity_status_master s ON s.entity_status_id = cv.current_status_id
     WHERE c.organization_id = @org AND s.status_code = N'EXPIRED' AND cv.effective_end IS NOT NULL;

    -- Assets that are in use for the technology sources (as 431 D24: not in
    -- acquisition, not lost / stolen, not disposed / archived).
    DECLARE @in_use TABLE (asset_id BIGINT NOT NULL PRIMARY KEY, asset_name NVARCHAR(400) NULL, severity_code NVARCHAR(10) NOT NULL);
    INSERT @in_use (asset_id, asset_name, severity_code)
    SELECT a.asset_id, a.asset_name, grac_practice.fn_asset_ntf_asset_severity(a.asset_id)
      FROM grac_practice.organization_dependency_asset a
      LEFT JOIN grac_practice.entity_status_master s ON s.entity_status_id = a.current_status_id
     WHERE a.organization_id = @org
       AND ISNULL(s.status_code, N'ACTIVE') NOT IN (N'DRAFT', N'REQUESTED', N'APPROVED', N'ORDERED', N'LOST', N'STOLEN',
                                                     N'DISPOSED', N'ARCHIVED');

    -- Model support end (9.1.3 "Model or OS support end"; D50).
    INSERT #due (occurrence_key, activity_code, object_type, object_id, ref_id, asset_id, contract_id, trigger_date,
                 object_ref, object_title, severity_code)
    SELECT DISTINCT CONCAT(N'TECH_SUPPORT_END:MODEL:', u.asset_id, N':', m.model_id, N':', CONVERT(NVARCHAR(8), x.d, 112)),
           N'TECH_SUPPORT_END', N'ASSET_MODEL', u.asset_id, m.model_id, u.asset_id, NULL, x.d,
           u.asset_name, CONCAT(N'Model ', m.model_name, N' support ends'), u.severity_code
      FROM @in_use u
      JOIN grac_practice.asset_field_value v ON v.asset_id = u.asset_id
      JOIN grac_practice.asset_field_definition fd ON fd.field_definition_id = v.field_definition_id AND fd.field_key = N'model'
      JOIN grac_practice.asset_model m ON m.model_id = v.value_ref
     CROSS APPLY (SELECT COALESCE(m.end_extended_support_date, m.end_security_support_date, m.end_standard_support_date) AS d) x
     WHERE x.d IS NOT NULL;

    -- Installed OS / firmware release support end (the 430 technology status).
    INSERT #due (occurrence_key, activity_code, object_type, object_id, ref_id, asset_id, contract_id, trigger_date,
                 object_ref, object_title, severity_code)
    SELECT CONCAT(x.act, N':', t.Kind, N':', u.asset_id, N':', t.CurrentReleaseId, N':', CONVERT(NVARCHAR(8), t.SupportEndDate, 112)),
           x.act, CASE t.Kind WHEN N'OS' THEN N'ASSET_OS' ELSE N'ASSET_FIRMWARE' END, u.asset_id, t.CurrentReleaseId, u.asset_id, NULL,
           t.SupportEndDate, u.asset_name, CONCAT(t.CurrentLabel, N' support ends'), u.severity_code
      FROM grac_practice.fn_asset_technology_status(@org, NULL) t
      JOIN @in_use u ON u.asset_id = t.AssetId
     CROSS APPLY (SELECT CASE t.Kind WHEN N'OS' THEN N'TECH_SUPPORT_END' ELSE N'FIRMWARE_SUPPORT_END' END AS act) x
     WHERE t.CurrentReleaseId IS NOT NULL AND t.SupportEndDate IS NOT NULL;

    -- Technology exception expiry (430).
    INSERT #due (occurrence_key, activity_code, object_type, object_id, ref_id, asset_id, contract_id, trigger_date,
                 object_ref, object_title, severity_code)
    SELECT CONCAT(N'EXCEPTION_EXPIRY:EXC:', x.exception_id, N':', CONVERT(NVARCHAR(8), x.expiry_date, 112)),
           N'EXCEPTION_EXPIRY', N'TECH_EXCEPTION', x.exception_id, NULL, x.asset_id, NULL, x.expiry_date,
           CONCAT(N'Exception #', x.exception_id),
           CONCAT(CASE x.technology_kind WHEN N'OS' THEN N'OS' ELSE N'Firmware' END, N' exception for ',
                  COALESCE(a.asset_name, N'model ' + m.model_name, N'-')),
           CASE WHEN x.asset_id IS NULL THEN N'MEDIUM' ELSE grac_practice.fn_asset_ntf_asset_severity(x.asset_id) END
      FROM grac_practice.asset_technology_exception x
      LEFT JOIN grac_practice.organization_dependency_asset a ON a.asset_id = x.asset_id
      LEFT JOIN grac_practice.asset_model m ON m.model_id = x.model_id
     WHERE x.organization_id = @org AND x.status = N'APPROVED';

    -- Custodian attestation (431): open attestations by due date.
    INSERT #due (occurrence_key, activity_code, object_type, object_id, ref_id, asset_id, contract_id, trigger_date,
                 object_ref, object_title, severity_code)
    SELECT CONCAT(N'CUSTODIAN_ATTESTATION:ATT:', t.attestation_id, N':', CONVERT(NVARCHAR(8), t.due_date, 112)),
           N'CUSTODIAN_ATTESTATION', N'ATTESTATION', t.attestation_id, NULL, t.asset_id, NULL, t.due_date,
           a.asset_name, CONCAT(N'Attestation of ', a.asset_name, N' (', LOWER(t.assignee_role), N')'),
           grac_practice.fn_asset_ntf_asset_severity(t.asset_id)
      FROM grac_practice.asset_attestation t
      JOIN grac_practice.organization_dependency_asset a ON a.asset_id = t.asset_id
     WHERE t.organization_id = @org AND t.status IN (N'GENERATED', N'PENDING', N'IN_PROGRESS', N'OVERDUE', N'ESCALATED');

    -- 438: recurring asset activities -- open asset-task occurrences by due date.
    INSERT #due (occurrence_key, activity_code, object_type, object_id, ref_id, asset_id, contract_id, trigger_date,
                 object_ref, object_title, severity_code)
    SELECT CONCAT(tp.notification_activity_code, N':ACT:', ao.occurrence_id, N':', CONVERT(NVARCHAR(8), ao.due_date, 112)),
           tp.notification_activity_code, N'ACTIVITY', ao.occurrence_id, NULL, ao.asset_id, cv.contract_id, ao.due_date,
           a.asset_name, CONCAT(tp.template_name, N' of ', a.asset_name),
           grac_practice.fn_asset_ntf_asset_severity(ao.asset_id)
      FROM grac_practice.asset_activity_occurrence ao
      JOIN grac_practice.asset_activity_template tp ON tp.template_code = ao.template_code
      JOIN grac_practice.organization_dependency_asset a ON a.asset_id = ao.asset_id
      LEFT JOIN grac_practice.asset_contract_version cv ON cv.version_id = ao.contract_version_id
     WHERE ao.organization_id = @org AND ao.status = N'OPEN' AND ao.decision = N'ASSET_TASK';

    -- 2. Close / reopen.
    UPDATE o
       SET status = CASE WHEN EXISTS (SELECT 1 FROM #due d WHERE d.activity_code = o.activity_code AND d.object_type = o.object_type
                                                                AND d.object_id = o.object_id)
                         THEN N'SUPERSEDED' ELSE N'COMPLETED' END,
           close_reason = CASE WHEN EXISTS (SELECT 1 FROM #due d WHERE d.activity_code = o.activity_code AND d.object_type = o.object_type
                                                                      AND d.object_id = o.object_id)
                               THEN N'The trigger date or reference changed; a new occurrence replaces it.'
                               ELSE N'No longer due (completed, renewed, changed or withdrawn).' END,
           closed_dt = SYSUTCDATETIME(), updated_by = @actor, updated_dt = SYSUTCDATETIME()
      FROM grac_practice.asset_notification_occurrence o
     WHERE o.organization_id = @org AND o.status = N'OPEN'
       AND NOT EXISTS (SELECT 1 FROM #due d WHERE d.occurrence_key = o.occurrence_key);
    SET @closed = @@ROWCOUNT;

    UPDATE o
       SET status = N'OPEN', closed_dt = NULL, close_reason = NULL, object_ref = d.object_ref, object_title = d.object_title,
           severity_code = d.severity_code, updated_by = @actor, updated_dt = SYSUTCDATETIME()
      FROM grac_practice.asset_notification_occurrence o
      JOIN #due d ON d.occurrence_key = o.occurrence_key
     WHERE o.organization_id = @org
       AND (o.status <> N'OPEN' OR ISNULL(o.object_title, N'') <> ISNULL(d.object_title, N'') OR o.severity_code <> d.severity_code
            OR ISNULL(o.object_ref, N'') <> ISNULL(d.object_ref, N''));

    -- 3. Open.
    INSERT grac_practice.asset_notification_occurrence
        (organization_id, occurrence_key, activity_code, object_type, object_id, ref_id, asset_id, contract_id, trigger_date,
         object_ref, object_title, severity_code, status, entered_by)
    SELECT @org, d.occurrence_key, d.activity_code, d.object_type, d.object_id, d.ref_id, d.asset_id, d.contract_id, d.trigger_date,
           d.object_ref, d.object_title, d.severity_code, N'OPEN', @actor
      FROM #due d
     WHERE NOT EXISTS (SELECT 1 FROM grac_practice.asset_notification_occurrence o
                        WHERE o.organization_id = @org AND o.occurrence_key = d.occurrence_key);
    SET @opened = @@ROWCOUNT;

    -- 4. Fire.
    CREATE TABLE #np (party_code NVARCHAR(30) NOT NULL, employee_id BIGINT NOT NULL);
    CREATE TABLE #rcp (employee_id BIGINT NULL, role_id BIGINT NULL, role_name NVARCHAR(200) NULL, reason_code NVARCHAR(30) NOT NULL);
    CREATE TABLE #holders (
        EmployeeId BIGINT, EmployeeCode NVARCHAR(100), EmployeeName NVARCHAR(240),
        Email NVARCHAR(250), Designation NVARCHAR(200), Department NVARCHAR(200),
        RoleId BIGINT, RoleName NVARCHAR(200)
    );

    DECLARE @occ BIGINT, @act NVARCHAR(40), @otype NVARCHAR(30), @oid BIGINT, @asset BIGINT, @contract BIGINT, @trigger DATE,
            @ref NVARCHAR(200), @title NVARCHAR(400), @sev NVARCHAR(10), @last_date DATE,
            @p BIGINT, @pver INT, @ack NVARCHAR(10), @wdays BIT, @channels NVARCHAR(60),
            @stage BIGINT, @sdate DATE, @kind NVARCHAR(12), @offset INT, @level TINYINT, @class NVARCHAR(20),
            @act_name NVARCHAR(160), @basis NVARCHAR(30), @subject NVARCHAR(400), @body NVARCHAR(MAX), @n INT,
            @role BIGINT, @role_name NVARCHAR(200);

    DECLARE occ_cur CURSOR LOCAL STATIC FOR
        SELECT o.occurrence_id, o.activity_code, o.object_type, o.object_id, o.asset_id, o.contract_id, o.trigger_date,
               o.object_ref, o.object_title, o.severity_code, o.last_stage_date
          FROM grac_practice.asset_notification_occurrence o
         WHERE o.organization_id = @org AND o.status = N'OPEN'
           AND (o.snoozed_until IS NULL OR o.snoozed_until <= @today)
         ORDER BY o.trigger_date, o.occurrence_id;
    OPEN occ_cur;
    FETCH NEXT FROM occ_cur INTO @occ, @act, @otype, @oid, @asset, @contract, @trigger, @ref, @title, @sev, @last_date;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            SELECT @p = NULL, @pver = NULL, @ack = NULL, @wdays = NULL, @channels = NULL,
                   @stage = NULL, @sdate = NULL, @kind = NULL, @offset = NULL, @level = NULL, @class = NULL;
            SELECT @p = ProfileId, @pver = VersionNo, @ack = AckMode, @wdays = WorkingDaysOnly, @channels = Channels
              FROM grac_practice.fn_asset_ntf_profile_for(@org, @act, @sev, @today);

            IF @p IS NOT NULL
                SELECT TOP 1 @stage = s.stage_id, @sdate = x.d, @kind = s.stage_kind, @offset = s.offset_days,
                       @level = s.escalation_level, @class = s.notification_class
                  FROM grac_practice.asset_notification_stage s
                 CROSS APPLY (SELECT grac_practice.fn_asset_ntf_stage_date(@trigger, s.stage_kind, s.offset_days, @wdays) AS d) x
                 WHERE s.profile_id = @p AND s.is_active = 1 AND x.d <= @today
                 ORDER BY x.d DESC, s.escalation_level DESC, s.stage_id DESC;

            IF @stage IS NOT NULL AND @sdate > ISNULL(@last_date, CONVERT(DATE, '19000101', 112))
            BEGIN
                -- 9.1.2: an escalation on a critical object is a Critical notification (D53).
                IF @sev = N'CRITICAL' AND @kind = N'ESCALATION' SET @class = N'CRITICAL';

                DELETE FROM #np;
                DELETE FROM #rcp;
                EXEC grac_practice.sp_asset_notification_parties @occurrence_id = @occ;

                INSERT #rcp (employee_id, role_id, role_name, reason_code)
                SELECT np.employee_id, NULL, NULL, sr.recipient_code
                  FROM grac_practice.asset_notification_stage_recipient sr
                  JOIN #np np ON np.party_code = sr.recipient_code
                 WHERE sr.stage_id = @stage AND sr.recipient_code <> N'ROLE';
                INSERT #rcp (employee_id, role_id, role_name, reason_code)
                SELECT np.employee_id, NULL, NULL, m.recipient_code
                  FROM grac_practice.asset_escalation_matrix m
                  JOIN #np np ON np.party_code = m.recipient_code
                 WHERE m.organization_id = @org AND m.severity_code = @sev AND m.escalation_level = @level
                   AND m.recipient_code <> N'ROLE';

                DECLARE role_cur CURSOR LOCAL STATIC FOR
                    SELECT DISTINCT r.role_id, r.role_name
                      FROM (SELECT sr.role_id FROM grac_practice.asset_notification_stage_recipient sr
                             WHERE sr.stage_id = @stage AND sr.recipient_code = N'ROLE'
                            UNION
                            SELECT m.role_id FROM grac_practice.asset_escalation_matrix m
                             WHERE m.organization_id = @org AND m.severity_code = @sev AND m.escalation_level = @level
                               AND m.recipient_code = N'ROLE') x
                      JOIN grac_practice.organization_role r ON r.role_id = x.role_id;
                OPEN role_cur;
                FETCH NEXT FROM role_cur INTO @role, @role_name;
                WHILE @@FETCH_STATUS = 0
                BEGIN
                    DELETE FROM #holders;
                    INSERT INTO #holders
                        EXEC grac_practice.sp_org_role_holders_list @organization_id = @org, @role_id = @role;
                    IF EXISTS (SELECT 1 FROM #holders)
                    BEGIN
                        INSERT #rcp (employee_id, role_id, role_name, reason_code)
                        SELECT EmployeeId, RoleId, RoleName, N'ROLE' FROM #holders;
                    END
                    ELSE
                    BEGIN
                        -- An empty role still records the obligation (213 precedent).
                        INSERT #rcp (employee_id, role_id, role_name, reason_code) VALUES (NULL, @role, @role_name, N'ROLE');
                    END
                    FETCH NEXT FROM role_cur INTO @role, @role_name;
                END
                CLOSE role_cur;
                DEALLOCATE role_cur;

                IF NOT EXISTS (SELECT 1 FROM #rcp)
                    INSERT #rcp (employee_id, role_id, role_name, reason_code) VALUES (NULL, NULL, NULL, N'UNRESOLVED');

                SELECT @act_name = activity_name, @basis = trigger_basis
                  FROM grac_practice.asset_notification_activity WHERE activity_code = @act;
                SET @subject = LEFT(CONCAT(N'[GRAC] ',
                    CASE @class WHEN N'INFORMATIONAL' THEN N'Information' WHEN N'REMINDER' THEN N'Reminder'
                                WHEN N'ESCALATION' THEN N'Escalation' ELSE N'Critical' END,
                    N': ', @act_name, N' - ', ISNULL(@ref, N'-'),
                    CASE @kind WHEN N'REMINDER' THEN CONCAT(N' due in ', @offset, N' day(s)')
                               WHEN N'DUE' THEN N' due today'
                               ELSE CASE WHEN @offset = 0 THEN N' reached its date' ELSE CONCAT(N' ', @offset, N' day(s) overdue') END END), 400);
                SET @body = CONCAT(
                    @act_name, CHAR(13), CHAR(10), CHAR(13), CHAR(10),
                    N'Reference: ', ISNULL(@ref, N'-'), CHAR(13), CHAR(10),
                    N'Subject:   ', ISNULL(@title, N'-'), CHAR(13), CHAR(10),
                    N'Date:      ', CONVERT(NVARCHAR(10), @trigger, 23), N' (', LOWER(REPLACE(@basis, N'_', N' ')), N')', CHAR(13), CHAR(10),
                    N'Stage:     ', CASE @kind WHEN N'REMINDER' THEN CONCAT(@offset, N' day(s) before')
                                               WHEN N'DUE' THEN N'due date'
                                               ELSE CONCAT(N'escalation level ', @level, N', ', @offset, N' day(s) after') END, CHAR(13), CHAR(10),
                    N'Severity:  ', @sev, CHAR(13), CHAR(10),
                    CASE @ack WHEN N'ACTION' THEN N'Acknowledge with the action taken.'
                              WHEN N'MANAGER' THEN N'Acknowledge with the action taken; your manager confirms the acknowledgement.'
                              WHEN N'READ' THEN N'Mark as read once seen.' ELSE N'' END);

                BEGIN TRAN;
                INSERT grac_practice.asset_notification_outbox
                    (organization_id, occurrence_id, profile_id, profile_version, stage_id, stage_kind, stage_offset_days, stage_date,
                     escalation_level, notification_class, activity_code, object_type, object_id, asset_id, contract_id, object_ref,
                     object_title, trigger_date, severity_code, recipient_employee_id, recipient_name, recipient_email,
                     recipient_manager_id, role_id, role_name, recipient_reason_code, channels, ack_mode, subject, body_text,
                     status_code, failure_reason, entered_by)
                SELECT @org, @occ, @p, @pver, @stage, @kind, @offset, @sdate, @level, @class, @act, @otype, @oid, @asset, @contract, @ref,
                       @title, @trigger, @sev, r.employee_id, e.employee_name, e.email, e.reporting_officer_id, r.role_id, r.role_name,
                       r.reason_code, @channels, @ack, @subject, @body,
                       CASE WHEN r.employee_id IS NULL THEN N'Suppressed' ELSE N'Pending' END,
                       CASE WHEN r.employee_id IS NULL AND r.reason_code = N'ROLE' THEN N'The role has no active holder.'
                            WHEN r.employee_id IS NULL THEN N'No recipient could be resolved for this stage.' END,
                       @actor
                  FROM (SELECT employee_id, role_id, role_name, reason_code,
                               ROW_NUMBER() OVER (PARTITION BY ISNULL(employee_id, -1)
                                                  ORDER BY CASE WHEN role_id IS NULL THEN 0 ELSE 1 END, reason_code) AS rn
                          FROM #rcp) r
                  LEFT JOIN grac_practice.organization_employee e ON e.employee_id = r.employee_id
                 WHERE r.rn = 1
                   AND NOT EXISTS (SELECT 1 FROM grac_practice.asset_notification_outbox x
                                    WHERE x.occurrence_id = @occ AND x.stage_id = @stage
                                      AND ((x.recipient_employee_id IS NULL AND r.employee_id IS NULL)
                                           OR x.recipient_employee_id = r.employee_id));
                SET @n = @@ROWCOUNT;
                UPDATE grac_practice.asset_notification_occurrence
                   SET last_stage_id = @stage, last_stage_date = @sdate,
                       escalation_level = CASE WHEN @level > escalation_level THEN @level ELSE escalation_level END,
                       last_notified_dt = SYSUTCDATETIME(), updated_by = @actor, updated_dt = SYSUTCDATETIME()
                 WHERE occurrence_id = @occ;
                COMMIT;
                SET @queued = @queued + @n;
            END
        END TRY
        BEGIN CATCH
            IF XACT_STATE() <> 0 ROLLBACK;
            IF CURSOR_STATUS('local', 'role_cur') >= -1
            BEGIN
                IF CURSOR_STATUS('local', 'role_cur') >= 0 CLOSE role_cur;
                DEALLOCATE role_cur;
            END
            SET @errors = @errors + 1;
            SET @error_text = LEFT(CONCAT(@error_text, CASE WHEN @error_text IS NULL THEN N'' ELSE CHAR(10) END,
                                          N'Occurrence ', @occ, N': ', ERROR_MESSAGE()), 4000);
        END CATCH
        FETCH NEXT FROM occ_cur INTO @occ, @act, @otype, @oid, @asset, @contract, @trigger, @ref, @title, @sev, @last_date;
    END
    CLOSE occ_cur;
    DEALLOCATE occ_cur;
END
GO
PRINT '439 rollback: sp_asset_notification_sweep restored.';
GO

-- 438 body (verbatim).
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_notification_parties
    @occurrence_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @org BIGINT, @otype NVARCHAR(30), @oid BIGINT, @asset BIGINT;
    SELECT @org = organization_id, @otype = object_type, @oid = object_id, @asset = asset_id
      FROM grac_practice.asset_notification_occurrence WHERE occurrence_id = @occurrence_id;
    IF @org IS NULL RETURN;

    DECLARE @raw TABLE (party_code NVARCHAR(30) NOT NULL, val NVARCHAR(100) NOT NULL);

    IF @asset IS NOT NULL
    BEGIN
        INSERT @raw (party_code, val)
        SELECT N'ASSET_OWNER', CAST(a.owner_id AS NVARCHAR(30))
          FROM grac_practice.organization_dependency_asset a
         WHERE a.asset_id = @asset AND a.owner_id IS NOT NULL;
        INSERT @raw (party_code, val)
        SELECT CASE v.FieldKey WHEN N'business_owner' THEN N'BUSINESS_OWNER' WHEN N'technical_owner' THEN N'TECHNICAL_OWNER'
                               WHEN N'custodian' THEN N'CUSTODIAN' WHEN N'maintenance_owner' THEN N'MAINTENANCE_OWNER'
                               WHEN N'compliance_owner' THEN N'COMPLIANCE_OWNER' WHEN N'privacy_owner' THEN N'PRIVACY_OWNER'
                               ELSE N'SECURITY_OWNER' END,
               LEFT(LTRIM(RTRIM(v.Value)), 100)
          FROM grac_practice.fn_asset_stored_values(@asset) v
         WHERE v.FieldKey IN (N'business_owner', N'technical_owner', N'custodian', N'maintenance_owner', N'compliance_owner',
                              N'privacy_owner', N'information_security_owner')
           AND NULLIF(LTRIM(RTRIM(v.Value)), N'') IS NOT NULL;
    END

    IF @otype = N'CONTRACT_VERSION'
    BEGIN
        INSERT @raw (party_code, val)
        SELECT x.code, CAST(x.emp AS NVARCHAR(30))
          FROM grac_practice.asset_contract_version cv
         CROSS APPLY (VALUES (N'CONTRACT_OWNER', cv.contract_owner_id), (N'PROCUREMENT_OWNER', cv.procurement_owner_id),
                             (N'ACTIVITY_OWNER', COALESCE(cv.contract_owner_id, cv.procurement_owner_id))) x(code, emp)
         WHERE cv.version_id = @oid AND x.emp IS NOT NULL;
        INSERT @raw (party_code, val)
        SELECT DISTINCT N'AFFECTED_ASSET_OWNERS', CAST(a.owner_id AS NVARCHAR(30))
          FROM grac_practice.asset_contract_coverage cc
          JOIN grac_practice.organization_dependency_asset a ON a.asset_id = cc.asset_id
         WHERE cc.version_id = @oid AND cc.coverage_state <> N'EXCLUDED' AND a.owner_id IS NOT NULL;
    END
    ELSE IF @otype = N'TECH_EXCEPTION'
    BEGIN
        INSERT @raw (party_code, val)
        SELECT x.code, CAST(x.emp AS NVARCHAR(30))
          FROM grac_practice.asset_technology_exception t
         CROSS APPLY (VALUES (N'ACTIVITY_OWNER', t.owner_employee_id), (N'EXCEPTION_APPROVER', t.decided_by_employee_id)) x(code, emp)
         WHERE t.exception_id = @oid AND x.emp IS NOT NULL;
    END
    ELSE IF @otype = N'ATTESTATION'
    BEGIN
        INSERT @raw (party_code, val)
        SELECT N'ACTIVITY_OWNER', CASE WHEN t.assignee_employee_id IS NOT NULL THEN CAST(t.assignee_employee_id AS NVARCHAR(30))
                                       ELSE N'T:' + CAST(t.assignee_team_id AS NVARCHAR(30)) END
          FROM grac_practice.asset_attestation t
         WHERE t.attestation_id = @oid AND (t.assignee_employee_id IS NOT NULL OR t.assignee_team_id IS NOT NULL);
    END
    ELSE IF @otype = N'ACTIVITY'                                                       -- 438
    BEGIN
        -- Activity owner: the task owner, else the template owner field, else
        -- the asset owner; the owner of the linked contract version too (9.1.4).
        INSERT @raw (party_code, val)
        SELECT TOP 1 N'ACTIVITY_OWNER', x.val
          FROM (SELECT 0 AS rk, CAST(t.assigned_to_employee_id AS NVARCHAR(100)) AS val
                  FROM grac_practice.asset_activity_occurrence ao
                  JOIN grac_practice.practice_task t ON t.task_id = ao.task_id
                 WHERE ao.occurrence_id = @oid AND t.assigned_to_employee_id IS NOT NULL
                UNION ALL
                SELECT 1, LEFT(v.value_text, 100)
                  FROM grac_practice.asset_activity_occurrence ao
                  JOIN grac_practice.asset_activity_template tp ON tp.template_code = ao.template_code
                  JOIN grac_practice.asset_field_value v ON v.asset_id = ao.asset_id
                  JOIN grac_practice.asset_field_definition f ON f.field_definition_id = v.field_definition_id
                                                             AND f.field_key = tp.owner_field_key
                 WHERE ao.occurrence_id = @oid
                UNION ALL
                SELECT 2, r.val FROM @raw r WHERE r.party_code = N'ASSET_OWNER') x
         ORDER BY x.rk;
        INSERT @raw (party_code, val)
        SELECT N'CONTRACT_OWNER', CAST(cv.contract_owner_id AS NVARCHAR(30))
          FROM grac_practice.asset_activity_occurrence ao
          JOIN grac_practice.asset_contract_version cv ON cv.version_id = ao.contract_version_id
         WHERE ao.occurrence_id = @oid AND cv.contract_owner_id IS NOT NULL;
    END
    ELSE IF @otype IN (N'ASSET_MODEL', N'ASSET_OS', N'ASSET_FIRMWARE')
    BEGIN
        INSERT @raw (party_code, val)
        SELECT TOP 1 N'ACTIVITY_OWNER', val
          FROM @raw WHERE party_code IN (N'TECHNICAL_OWNER', N'ASSET_OWNER')
         ORDER BY CASE party_code WHEN N'TECHNICAL_OWNER' THEN 0 ELSE 1 END;
    END

    INSERT #np (party_code, employee_id)
    SELECT DISTINCT r.party_code, e.employee_id
      FROM @raw r
     CROSS APPLY (SELECT CASE WHEN r.val LIKE N'T:%' THEN NULL
                              WHEN r.val LIKE N'E:%' THEN TRY_CONVERT(BIGINT, SUBSTRING(r.val, 3, 40))
                              ELSE TRY_CONVERT(BIGINT, r.val) END AS emp,
                         CASE WHEN r.val LIKE N'T:%' THEN TRY_CONVERT(BIGINT, SUBSTRING(r.val, 3, 40)) END AS team) x
      JOIN grac_practice.organization_employee e
        ON e.organization_id = @org AND e.status = N'Active'
       AND (e.employee_id = x.emp
            OR EXISTS (SELECT 1 FROM grac_practice.organization_team_member m
                        WHERE m.team_id = x.team AND m.employee_id = e.employee_id AND m.status = N'Active'));

    INSERT #np (party_code, employee_id)
    SELECT DISTINCT N'MANAGER', m.employee_id
      FROM #np o
      JOIN grac_practice.organization_employee e ON e.employee_id = o.employee_id
      JOIN grac_practice.organization_employee m ON m.employee_id = e.reporting_officer_id AND m.status = N'Active'
     WHERE o.party_code = N'ACTIVITY_OWNER';

    INSERT #np (party_code, employee_id)
    SELECT DISTINCT N'DEPARTMENT_HEAD', h.employee_id
      FROM #np o
      JOIN grac_practice.organization_employee e ON e.employee_id = o.employee_id
      JOIN grac_practice.organization_department d ON d.department_id = e.department_id
      JOIN grac_practice.organization_employee h ON h.employee_id = d.head_employee_id AND h.status = N'Active'
     WHERE o.party_code = N'ACTIVITY_OWNER';
END
GO
PRINT '439 rollback: sp_asset_notification_parties restored.';
GO

-- 438 body (verbatim).
CREATE OR ALTER FUNCTION grac_practice.fn_asset_stored_values (@asset_id BIGINT)
RETURNS TABLE
AS
RETURN
    SELECT d.field_definition_id AS FieldDefinitionId, d.field_key AS FieldKey, c.val AS Value
      FROM grac_practice.organization_dependency_asset a
     CROSS APPLY (VALUES
        (N'asset_id',             CAST(a.asset_id AS NVARCHAR(MAX))),
        (N'asset_name',           CAST(a.asset_name AS NVARCHAR(MAX))),
        (N'asset_category_id',    CAST(a.asset_category_id AS NVARCHAR(MAX))),
        (N'asset_subcategory_id', CAST(a.asset_subcategory_id AS NVARCHAR(MAX))),
        (N'asset_type_id',        CAST(a.asset_type_id AS NVARCHAR(MAX))),
        (N'organization_id',      CAST(a.organization_id AS NVARCHAR(MAX))),
        (N'location_id',          CAST(a.location_id AS NVARCHAR(MAX))),
        (N'owner_id',             CAST(a.owner_id AS NVARCHAR(MAX))),
        (N'purchase_dt',          CONVERT(NVARCHAR(MAX), a.purchase_dt, 23)),
        (N'warranty_expiry_dt',   CONVERT(NVARCHAR(MAX), a.warranty_expiry_dt, 23)),
        (N'amc_expiry_dt',        CONVERT(NVARCHAR(MAX), a.amc_expiry_dt, 23)),
        (N'criticality_id',       CAST(a.criticality_id AS NVARCHAR(MAX))),
        (N'remarks',              CAST(a.remarks AS NVARCHAR(MAX))),
        (N'entered_by',           CAST(a.entered_by AS NVARCHAR(MAX))),
        (N'entered_dt',           CONVERT(NVARCHAR(MAX), a.entered_dt, 126)),
        (N'updated_by',           CAST(a.updated_by AS NVARCHAR(MAX))),
        (N'updated_dt',           CONVERT(NVARCHAR(MAX), a.updated_dt, 126))
     ) AS c(column_name, val)
      JOIN grac_practice.asset_field_definition d ON d.storage_kind = N'COLUMN' AND d.column_name = c.column_name
     WHERE a.asset_id = @asset_id AND c.val IS NOT NULL
    UNION ALL
    SELECT v.field_definition_id, d.field_key, v.value_text
      FROM grac_practice.asset_field_value v
      JOIN grac_practice.asset_field_definition d ON d.field_definition_id = v.field_definition_id
     WHERE v.asset_id = @asset_id
    UNION ALL
    SELECT d.field_definition_id, d.field_key, s.status_code
      FROM grac_practice.organization_dependency_asset a
      JOIN grac_practice.entity_status_master s ON s.entity_status_id = a.current_status_id
      JOIN grac_practice.asset_field_definition d ON d.field_key = N'asset_status'
     WHERE a.asset_id = @asset_id
    UNION ALL
    -- 435: the calculated coverage status (5.1.11).
    SELECT d.field_definition_id, d.field_key, cs.CoverageStatusLabel
      FROM grac_practice.organization_dependency_asset a
     CROSS APPLY grac_practice.fn_asset_coverage_summary(a.organization_id, a.asset_id) cs
      JOIN grac_practice.asset_field_definition d ON d.field_key = N'coverage_status'
     WHERE a.asset_id = @asset_id
    UNION ALL
    -- 438: next calibration / maintenance / inspection date and calibration /
    -- maintenance status from the activity schedule (5.1.7), unless a value
    -- is stored for the field.
    SELECT d.field_definition_id, d.field_key, x.val
      FROM grac_practice.asset_activity_schedule s
      JOIN grac_practice.asset_activity_template t ON t.template_code = s.template_code
     CROSS APPLY (VALUES
        (t.next_date_field_key, CONVERT(NVARCHAR(MAX), s.next_due_date, 23)),
        (t.status_field_key,
         CASE WHEN t.status_field_key = N'maintenance_status'
                   AND EXISTS (SELECT 1 FROM grac_practice.asset_activity_occurrence o
                                WHERE o.asset_id = s.asset_id AND o.template_code = s.template_code
                                  AND o.status = N'OPEN' AND o.task_id IS NOT NULL) THEN N'In Progress'
              WHEN t.status_field_key = N'maintenance_status' THEN
                   CASE s.status_code WHEN N'VALID' THEN N'Not Due' WHEN N'DUE_SOON' THEN N'Due Soon' WHEN N'OVERDUE' THEN N'Overdue' END
              ELSE CASE s.status_code WHEN N'VALID' THEN N'Valid' WHEN N'DUE_SOON' THEN N'Due Soon' WHEN N'OVERDUE' THEN N'Overdue'
                                      WHEN N'NOT_APPLICABLE' THEN N'N/A' END END)
     ) AS x(field_key, val)
      JOIN grac_practice.asset_field_definition d ON d.field_key = x.field_key
     WHERE s.asset_id = @asset_id AND x.val IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM grac_practice.asset_field_value v
                        WHERE v.asset_id = @asset_id AND v.field_definition_id = d.field_definition_id);
GO
PRINT '439 rollback: fn_asset_stored_values restored.';
GO

-- 438 body (verbatim).
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_activity_config_get
    @organization_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 54650, 'Organization not found.', 1;
    SELECT t.template_code AS TemplateCode, t.template_name AS TemplateName, t.activity_kind AS ActivityKind, t.description AS Description,
           t.required_field_key AS RequiredFieldKey, t.frequency_field_key AS FrequencyFieldKey, t.basis_field_key AS BasisFieldKey,
           t.last_date_field_key AS LastDateFieldKey, t.expiry_field_key AS ExpiryFieldKey, t.owner_field_key AS OwnerFieldKey,
           t.coverage_types AS CoverageTypes, t.notification_activity_code AS NotificationActivityCode, na.activity_name AS NotificationActivityName,
           st.IsActive, st.LeadDays, st.DueSoonDays, st.GroupingMode, st.CampaignOwnerEmployeeId, ow.employee_name AS CampaignOwnerName,
           t.default_lead_days AS DefaultLeadDays, t.default_due_soon_days AS DefaultDueSoonDays,
           CASE WHEN s.organization_id IS NULL THEN 0 ELSE 1 END AS IsCustomized
      FROM grac_practice.asset_activity_template t
      JOIN grac_practice.fn_asset_activity_settings(@organization_id) st ON st.TemplateCode = t.template_code
      JOIN grac_practice.asset_notification_activity na ON na.activity_code = t.notification_activity_code
      LEFT JOIN grac_practice.asset_activity_setting s ON s.organization_id = @organization_id AND s.template_code = t.template_code
      LEFT JOIN grac_practice.organization_employee ow ON ow.employee_id = st.CampaignOwnerEmployeeId
     ORDER BY t.display_order;
    SELECT employee_id AS EmployeeId, employee_name AS EmployeeName
      FROM grac_practice.organization_employee
     WHERE organization_id = @organization_id AND status = N'Active'
     ORDER BY employee_name;
END
GO
PRINT '439 rollback: sp_asset_activity_config_get restored.';
GO

-- 438 body (verbatim).
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_activity_setting_save
    @organization_id            BIGINT,
    @template_code              NVARCHAR(40),
    @is_active                  BIT           = 1,
    @lead_days                  INT           = NULL,
    @due_soon_days              INT           = NULL,
    @grouping_mode              NVARCHAR(12)  = N'INDIVIDUAL',
    @campaign_owner_employee_id BIGINT        = NULL,
    @actor                      NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @actor = ISNULL(NULLIF(@actor, N''), N'system');
    SET @grouping_mode = UPPER(ISNULL(NULLIF(LTRIM(RTRIM(@grouping_mode)), N''), N'INDIVIDUAL'));
    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 54650, 'Organization not found.', 1;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.asset_activity_template WHERE template_code = @template_code)
        THROW 54651, 'Unknown activity template.', 1;
    IF @lead_days IS NULL OR @lead_days NOT BETWEEN 0 AND 365 OR @due_soon_days IS NULL OR @due_soon_days NOT BETWEEN 0 AND 365
        THROW 54652, 'Task lead days and due-soon days must be between 0 and 365.', 1;
    IF @grouping_mode NOT IN (N'INDIVIDUAL', N'CAMPAIGN')
        THROW 54653, 'Tasks are created individually or grouped in a monthly campaign.', 1;
    IF @campaign_owner_employee_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM grac_practice.organization_employee
                                                                WHERE employee_id = @campaign_owner_employee_id
                                                                  AND organization_id = @organization_id AND status = N'Active')
        THROW 54654, 'The campaign owner must be an active employee of the organization.', 1;
    DECLARE @before NVARCHAR(MAX) = (SELECT is_active AS isActive, lead_days AS leadDays, due_soon_days AS dueSoonDays,
                                            grouping_mode AS groupingMode, campaign_owner_employee_id AS campaignOwnerEmployeeId
                                       FROM grac_practice.asset_activity_setting
                                      WHERE organization_id = @organization_id AND template_code = @template_code
                                        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
    BEGIN TRAN;
    MERGE grac_practice.asset_activity_setting AS t
    USING (SELECT @organization_id AS organization_id, @template_code AS template_code) AS s
    ON t.organization_id = s.organization_id AND t.template_code = s.template_code
    WHEN MATCHED THEN UPDATE SET
        is_active = ISNULL(@is_active, 1), lead_days = @lead_days, due_soon_days = @due_soon_days, grouping_mode = @grouping_mode,
        campaign_owner_employee_id = @campaign_owner_employee_id, updated_by = @actor, updated_dt = SYSUTCDATETIME()
    WHEN NOT MATCHED THEN
        INSERT (organization_id, template_code, is_active, lead_days, due_soon_days, grouping_mode, campaign_owner_employee_id, entered_by)
        VALUES (@organization_id, @template_code, ISNULL(@is_active, 1), @lead_days, @due_soon_days, @grouping_mode,
                @campaign_owner_employee_id, @actor);
    INSERT grac_practice.practice_audit_trace (entity_type, entity_id, action_type, before_json, after_json, status, entered_by)
    VALUES (N'asset-activity-setting', @organization_id, CASE WHEN @before IS NULL THEN N'CREATE' ELSE N'UPDATE' END, @before,
            (SELECT @template_code AS templateCode, ISNULL(@is_active, 1) AS isActive, @lead_days AS leadDays, @due_soon_days AS dueSoonDays,
                    @grouping_mode AS groupingMode, @campaign_owner_employee_id AS campaignOwnerEmployeeId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            N'Active', @actor);
    COMMIT;
    SELECT @organization_id AS OrganizationId, N'SAVED' AS Result;
END
GO
PRINT '439 rollback: sp_asset_activity_setting_save restored.';
GO

-- 438 body (verbatim).
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_activity_schedules
    @organization_id BIGINT,
    @template_code   NVARCHAR(40)  = NULL,
    @status          NVARCHAR(16)  = NULL,
    @search          NVARCHAR(200) = NULL,
    @page_number     INT           = 1,
    @page_size       INT           = 25,
    @actor           NVARCHAR(100) = N'system'
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM grac_practice.organization WHERE organization_id = @organization_id)
        THROW 54650, 'Organization not found.', 1;
    SET @template_code = NULLIF(LTRIM(RTRIM(@template_code)), N'');
    SET @status = NULLIF(UPPER(LTRIM(RTRIM(@status))), N'');
    SET @search = NULLIF(LTRIM(RTRIM(@search)), N'');
    SET @page_number = CASE WHEN ISNULL(@page_number, 1) < 1 THEN 1 ELSE @page_number END;
    SET @page_size = CASE WHEN ISNULL(@page_size, 25) < 1 THEN 25 WHEN @page_size > 200 THEN 200 ELSE @page_size END;
    DECLARE @done INT;
    EXEC grac_practice.sp_asset_activity_task_sync @organization_id = @organization_id, @actor = @actor, @completed = @done OUTPUT;
    EXEC grac_practice.sp_asset_activity_schedule_sync @organization_id = @organization_id;
    DECLARE @today DATE = CAST(SYSUTCDATETIME() AS DATE);

    SELECT s.asset_id AS AssetId, a.asset_name AS AssetName, ty.asset_type_name AS AssetTypeName, s.template_code AS TemplateCode,
           t.template_name AS TemplateName, t.activity_kind AS ActivityKind, s.schedule_state AS ScheduleState,
           s.not_scheduled_reason AS NotScheduledReason, s.frequency_text AS FrequencyText, s.basis AS Basis,
           s.last_done_date AS LastDoneDate, s.next_due_date AS NextDueDate, DATEDIFF(DAY, @today, s.next_due_date) AS DaysToDue,
           s.due_source AS DueSource, s.status_code AS StatusCode,
           c.contract_number AS ContractNumber, v.version_no AS ContractVersionNo, s.coverage_end AS CoverageEnd,
           o.occurrence_id AS OpenOccurrenceId, o.occurrence_key AS OpenOccurrenceKey, o.task_id AS OpenTaskId,
           o.needs_reconciliation AS NeedsReconciliation,
           COUNT(*) OVER () AS TotalRows
      FROM grac_practice.asset_activity_schedule s
      JOIN grac_practice.asset_activity_template t ON t.template_code = s.template_code
      JOIN grac_practice.organization_dependency_asset a ON a.asset_id = s.asset_id
      LEFT JOIN grac_practice.dependency_asset_type_master ty ON ty.asset_type_id = a.asset_type_id
      LEFT JOIN grac_practice.asset_contract_version v ON v.version_id = s.contract_version_id
      LEFT JOIN grac_practice.asset_contract c ON c.contract_id = v.contract_id
      LEFT JOIN grac_practice.asset_activity_occurrence o ON o.asset_id = s.asset_id AND o.template_code = s.template_code AND o.status = N'OPEN'
     WHERE s.organization_id = @organization_id
       AND (@template_code IS NULL OR s.template_code = @template_code)
       AND ((@status IS NULL AND s.status_code <> N'NOT_APPLICABLE') OR @status = N'ALL' OR s.status_code = @status)
       AND (@search IS NULL OR a.asset_name LIKE N'%' + @search + N'%' OR ty.asset_type_name LIKE N'%' + @search + N'%')
     ORDER BY CASE s.status_code WHEN N'OVERDUE' THEN 0 WHEN N'DUE_SOON' THEN 1 WHEN N'VALID' THEN 2 WHEN N'COVERED' THEN 3
                                 WHEN N'NOT_SCHEDULED' THEN 4 ELSE 5 END,
              s.next_due_date, a.asset_name, t.display_order
    OFFSET (@page_number - 1) * @page_size ROWS FETCH NEXT @page_size ROWS ONLY;
END
GO
PRINT '439 rollback: sp_asset_activity_schedules restored.';
GO

-- 438 body (verbatim).
CREATE OR ALTER PROCEDURE grac_practice.sp_asset_activity_occurrences
    @organization_id BIGINT,
    @template_code   NVARCHAR(40)  = NULL,
    @status          NVARCHAR(12)  = N'OPEN',
    @reconcile_only  BIT           = 0,
    @campaign_id     BIGINT        = NULL,
    @search          NVARCHAR(200) = NULL,
    @page_number     INT           = 1,
    @page_size       INT           = 25
AS
BEGIN
    SET NOCOUNT ON;
    SET @template_code = NULLIF(LTRIM(RTRIM(@template_code)), N'');
    SET @status = UPPER(ISNULL(NULLIF(LTRIM(RTRIM(@status)), N''), N'OPEN'));
    SET @search = NULLIF(LTRIM(RTRIM(@search)), N'');
    SET @page_number = CASE WHEN ISNULL(@page_number, 1) < 1 THEN 1 ELSE @page_number END;
    SET @page_size = CASE WHEN ISNULL(@page_size, 25) < 1 THEN 25 WHEN @page_size > 200 THEN 200 ELSE @page_size END;
    DECLARE @today DATE = CAST(SYSUTCDATETIME() AS DATE);

    SELECT o.occurrence_id AS OccurrenceId, o.occurrence_key AS OccurrenceKey, o.asset_id AS AssetId, a.asset_name AS AssetName,
           o.template_code AS TemplateCode, t.template_name AS TemplateName, o.due_date AS DueDate,
           DATEDIFF(DAY, @today, o.due_date) AS DaysToDue, o.sequence_no AS SequenceNo, o.decision AS Decision,
           o.decision_reason AS DecisionReason, c.contract_number AS ContractNumber, v.version_no AS ContractVersionNo,
           cm.campaign_key AS CampaignKey, cm.campaign_name AS CampaignName, o.task_id AS TaskId, pt.task_number AS TaskNumber,
           ts.status_name AS TaskStatusName, ae.employee_name AS TaskOwnerName, o.task_error AS TaskError, o.status AS Status,
           o.needs_reconciliation AS NeedsReconciliation, o.reconciliation_reason AS ReconciliationReason,
           o.reconciled_note AS ReconciledNote, o.reconciled_by AS ReconciledBy, o.reconciled_dt AS ReconciledDt,
           o.completed_dt AS CompletedDt, cb.employee_name AS CompletedByName, o.entered_dt AS OpenedDt,
           CONVERT(BIGINT, o.record_version) AS RecordVersion,
           COUNT(*) OVER () AS TotalRows
      FROM grac_practice.asset_activity_occurrence o
      JOIN grac_practice.asset_activity_template t ON t.template_code = o.template_code
      JOIN grac_practice.organization_dependency_asset a ON a.asset_id = o.asset_id
      LEFT JOIN grac_practice.asset_contract_version v ON v.version_id = o.contract_version_id
      LEFT JOIN grac_practice.asset_contract c ON c.contract_id = v.contract_id
      LEFT JOIN grac_practice.asset_activity_campaign cm ON cm.campaign_id = o.campaign_id
      LEFT JOIN grac_practice.practice_task pt ON pt.task_id = o.task_id
      LEFT JOIN grac_practice.entity_status_master ts ON ts.entity_status_id = pt.current_status_id
      LEFT JOIN grac_practice.organization_employee ae ON ae.employee_id = pt.assigned_to_employee_id
      LEFT JOIN grac_practice.organization_employee cb ON cb.employee_id = o.completed_by_employee_id
     WHERE o.organization_id = @organization_id
       AND (@template_code IS NULL OR o.template_code = @template_code)
       AND (@status = N'ALL' OR o.status = @status)
       AND (ISNULL(@reconcile_only, 0) = 0 OR o.needs_reconciliation = 1)
       AND (@campaign_id IS NULL OR o.campaign_id = @campaign_id)
       AND (@search IS NULL OR a.asset_name LIKE N'%' + @search + N'%' OR o.occurrence_key LIKE N'%' + @search + N'%')
     ORDER BY o.due_date, o.occurrence_id
    OFFSET (@page_number - 1) * @page_size ROWS FETCH NEXT @page_size ROWS ONLY;
END
GO
PRINT '439 rollback: sp_asset_activity_occurrences restored.';
GO

-- 438 body (verbatim).
CREATE OR ALTER FUNCTION grac_practice.fn_asset_activity_settings (@organization_id BIGINT)
RETURNS TABLE
AS
RETURN
    SELECT t.template_code AS TemplateCode, t.template_name AS TemplateName, t.activity_kind AS ActivityKind,
           CAST(ISNULL(s.is_active, 1) AS BIT) AS IsActive, ISNULL(s.lead_days, t.default_lead_days) AS LeadDays,
           ISNULL(s.due_soon_days, t.default_due_soon_days) AS DueSoonDays, ISNULL(s.grouping_mode, N'INDIVIDUAL') AS GroupingMode,
           s.campaign_owner_employee_id AS CampaignOwnerEmployeeId
      FROM grac_practice.asset_activity_template t
      LEFT JOIN grac_practice.asset_activity_setting s ON s.organization_id = @organization_id AND s.template_code = t.template_code;
GO
PRINT '439 rollback: fn_asset_activity_settings restored.';
GO

UPDATE grac_practice.asset_activity_occurrence SET status = N'CANCELLED', updated_by = N'rollback-439', updated_dt = SYSUTCDATETIME()
 WHERE status = N'WAIVED';
IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_asset_act_occ_status')
    ALTER TABLE grac_practice.asset_activity_occurrence DROP CONSTRAINT ck_pm_asset_act_occ_status;
ALTER TABLE grac_practice.asset_activity_occurrence WITH CHECK
    ADD CONSTRAINT ck_pm_asset_act_occ_status CHECK (status IN (N'OPEN', N'COMPLETED', N'CANCELLED', N'COVERED'));
GO

DROP TABLE IF EXISTS grac_practice.asset_restrictive_review;
DROP TABLE IF EXISTS grac_practice.asset_activity_disposition;
DROP TABLE IF EXISTS grac_practice.asset_activity_result;
DROP TABLE IF EXISTS grac_practice.asset_evidence_field;
PRINT '439 rollback: tables dropped.';
GO

IF COL_LENGTH('grac_practice.asset_activity_occurrence', 'is_retest') IS NOT NULL
BEGIN
    ALTER TABLE grac_practice.asset_activity_occurrence DROP CONSTRAINT df_pm_asset_act_occ_retest;
    ALTER TABLE grac_practice.asset_activity_occurrence DROP COLUMN revised_due_date, review_date, is_retest;
END
GO
IF COL_LENGTH('grac_practice.asset_activity_schedule', 'revised_due_date') IS NOT NULL
    ALTER TABLE grac_practice.asset_activity_schedule DROP COLUMN revised_due_date;
GO
IF COL_LENGTH('grac_practice.asset_activity_setting', 'result_review_required') IS NOT NULL
    ALTER TABLE grac_practice.asset_activity_setting
        DROP COLUMN result_review_required, disposition_approval_required, restrict_on_overdue, restrict_on_fail;
GO
IF COL_LENGTH('grac_practice.asset_activity_template', 'result_required') IS NOT NULL
BEGIN
    ALTER TABLE grac_practice.asset_activity_template DROP CONSTRAINT df_pm_asset_act_tpl_resreq, df_pm_asset_act_tpl_review,
                                                                      df_pm_asset_act_tpl_dispapp, df_pm_asset_act_tpl_rfail;
    ALTER TABLE grac_practice.asset_activity_template
        DROP COLUMN result_required, default_result_review, default_disposition_approval, retest_days,
                    certificate_number_field_key, certificate_expiry_field_key, default_restrict_on_overdue, default_restrict_on_fail;
END
PRINT '439 rollback: columns dropped.';
GO

UPDATE grac_practice.asset_notification_activity
   SET source_available = 0, source_note = N'Raised with task evidence (Phase 6.3).'      -- the 437 text
 WHERE activity_code = N'EVIDENCE_EXPIRY' AND source_available = 1;
IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'ck_pm_asset_ntf_occ_obj')
    ALTER TABLE grac_practice.asset_notification_occurrence DROP CONSTRAINT ck_pm_asset_ntf_occ_obj;
ALTER TABLE grac_practice.asset_notification_occurrence WITH NOCHECK
    ADD CONSTRAINT ck_pm_asset_ntf_occ_obj
        CHECK (object_type IN (N'CONTRACT_VERSION', N'ASSET_MODEL', N'ASSET_OS', N'ASSET_FIRMWARE',
                               N'TECH_EXCEPTION', N'ATTESTATION', N'ACTIVITY'));
PRINT '439 rollback: notification vocabulary restored.';
GO

SELECT '439 rollback' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.asset_activity_result','U') IS NULL
             AND OBJECT_ID('grac_practice.asset_restrictive_review','U') IS NULL
             AND COL_LENGTH('grac_practice.asset_activity_occurrence', 'revised_due_date') IS NULL
             AND COL_LENGTH('grac_practice.asset_activity_template', 'result_required') IS NULL
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_asset_activity_run')) NOT LIKE '%restrictive%'
             AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_asset_notification_sweep')) NOT LIKE '%EVIDENCE_EXPIRY:EV:%'
            THEN 'PASS' ELSE 'FAIL' END AS Result;
GO
