-- =====================================================================
-- 377_task_calendar_edit_scheduler_execution_date_only.sql
--
-- Task Calendar -- Edit Scheduler restriction (change request 2026-09-23)
--
-- WHAT CHANGES
-- ------------
-- The Edit Schedule dialog (Calendar.cshtml / practice-calendar.js) drops
-- "Skip This Occurrence": every occurrence must stay on the calendar, so
-- the only thing an edit can do is move it to a new Execution Date. The
-- Web tier will stop offering the Skip choice in the UI, but per this
-- project's own instruction ("Ensure the backend also enforces that only
-- the execution date can be updated; do not rely only on frontend
-- disabling/hiding") the database must refuse a Skipped override too,
-- independent of whatever the browser sends.
--
-- Reason and "apply to all future occurrences" are UNCHANGED -- only
-- Skip is removed; those two fields keep working exactly as they do
-- today (confirmed with the requester rather than assumed).
--
-- WHY A NEW SHIM RATHER THAN EDITING 002
-- ---------------------------------------
-- dbo.pm_manage_practice_repository is the 2,000+ line monolith; CREATE
-- OR ALTER can only replace it whole, so (as migrations 134/361/370
-- already established) logic that needs to diverge from it moves into a
-- small dedicated procedure and PracticeRepositoryService.ResolveProcedureAsync
-- routes the entity type there instead. Same 7-parameter gateway-shim
-- contract as sp_org_committee_repository_manage (370): SAVE is
-- intercepted here; every other action (there is none in practice for
-- this entity, but the pattern is kept for consistency) falls through to
-- the untouched 'assurance-schedule-overrides' branch of 002.
--
-- If this migration is not applied, ResolveProcedureAsync's ShimExistsAsync
-- probe finds nothing and the monolith's own branch keeps handling saves
-- exactly as it always has (Skip still reachable) -- an unapplied
-- migration degrades a restriction, it does not break the screen.
--
-- SAFE TO RE-RUN. NO SCHEMA CHANGE. NO DATA CHANGE. One procedure, added.
-- Rollback: 377_task_calendar_edit_scheduler_execution_date_only_rollback.sql
-- ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.assurance_schedule_override','U') IS NULL
BEGIN
    PRINT 'ABORT (377): grac_practice.assurance_schedule_override missing -- run 029 first.';
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- sp_pm_schedule_override_repository_manage -- 7-parameter monolith-
-- contract gateway shim for 'assurance-schedule-overrides' SAVE.
--
-- Identical INSERT/UPDATE shape to 002's own branch (scheduleRuleId,
-- organizationId, originalDate, newDate, reason, applyToFuture,
-- overrideBy all still read from @p_payload the same way) with exactly
-- one difference: @ovr_type is no longer read from the payload at all.
-- It is hard-coded to 'Moved', so a tampered or stale client that still
-- posts overrideType:'Skipped' cannot create a Skipped override -- the
-- restriction holds even if the browser's own hiding of the option were
-- bypassed.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_pm_schedule_override_repository_manage
    @p_entity_type NVARCHAR(100),
    @p_action      NVARCHAR(30),
    @p_id          BIGINT = 0,
    @p_search      NVARCHAR(250) = '',
    @p_status      NVARCHAR(30) = '',
    @p_payload     NVARCHAR(MAX) = '{}',
    @p_usr_id      NVARCHAR(100) = ''
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @p_action  = ISNULL(@p_action, '');
    SET @p_payload = ISNULL(NULLIF(@p_payload, ''), '{}');
    SET @p_usr_id  = ISNULL(NULLIF(@p_usr_id, ''), 'system');

    IF @p_action <> N'SAVE' AND @p_action <> N''
    BEGIN
        EXEC dbo.pm_manage_practice_repository
             @p_entity_type = @p_entity_type, @p_action = @p_action, @p_id = @p_id,
             @p_search = @p_search, @p_status = @p_status,
             @p_payload = @p_payload, @p_usr_id = @p_usr_id;
        RETURN;
    END

    BEGIN TRAN;

    DECLARE @ovr_rule_id  BIGINT = TRY_CONVERT(BIGINT, NULLIF(JSON_VALUE(@p_payload,'$.scheduleRuleId'), ''));
    DECLARE @ovr_org_id   BIGINT = TRY_CONVERT(BIGINT, NULLIF(JSON_VALUE(@p_payload,'$.organizationId'), ''));
    DECLARE @ovr_original DATE   = TRY_CONVERT(DATE, JSON_VALUE(@p_payload,'$.originalDate'));
    -- Task Calendar Edit Scheduler (2026-09-23): Skip This Occurrence is
    -- removed. Every save this procedure handles is a move, regardless
    -- of what @p_payload's own overrideType claims.
    DECLARE @ovr_type     NVARCHAR(30) = N'Moved';
    DECLARE @ovr_new_date DATE   = TRY_CONVERT(DATE, JSON_VALUE(@p_payload,'$.newDate'));

    IF @ovr_rule_id IS NULL
    BEGIN
        ROLLBACK;
        THROW 52030, 'Schedule rule is required.', 1;
    END
    IF @ovr_original IS NULL
    BEGIN
        ROLLBACK;
        THROW 52031, 'Original date is required.', 1;
    END
    IF @ovr_new_date IS NULL
    BEGIN
        ROLLBACK;
        THROW 52032, 'New Execution Date is required.', 1;
    END
    IF @ovr_org_id IS NULL
        SELECT @ovr_org_id = organization_id FROM grac_practice.assurance_schedule_rule WHERE schedule_rule_id = @ovr_rule_id;

    DECLARE @new_id BIGINT = @p_id;

    IF @p_id = 0
    BEGIN
        INSERT grac_practice.assurance_schedule_override
            (schedule_rule_id, organization_id, original_date, override_type, new_date, reason, apply_to_future, override_by, entered_by)
        VALUES
            (@ovr_rule_id, @ovr_org_id, @ovr_original, @ovr_type, @ovr_new_date,
             JSON_VALUE(@p_payload,'$.reason'),
             COALESCE(TRY_CONVERT(BIT, JSON_VALUE(@p_payload,'$.applyToFuture')), 0),
             JSON_VALUE(@p_payload,'$.overrideBy'), @p_usr_id);
        SET @new_id = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        UPDATE grac_practice.assurance_schedule_override
        SET override_type   = @ovr_type,
            new_date         = @ovr_new_date,
            reason           = JSON_VALUE(@p_payload,'$.reason'),
            apply_to_future  = COALESCE(TRY_CONVERT(BIT, JSON_VALUE(@p_payload,'$.applyToFuture')), 0),
            override_by      = JSON_VALUE(@p_payload,'$.overrideBy'),
            status           = COALESCE(NULLIF(JSON_VALUE(@p_payload,'$.status'), ''), 'Active'),
            updated_by       = @p_usr_id,
            updated_dt       = SYSUTCDATETIME()
        WHERE override_id = @p_id;
    END

    -- Same audit row the monolith writes for every save (134/370's own
    -- reasoning), so the trace stays continuous across the shim boundary.
    INSERT grac_practice.practice_audit_trace
        (entity_type, entity_id, action_type, after_json, status, entered_by)
    VALUES (@p_entity_type, @new_id, N'SAVE', @p_payload, 'Active', @p_usr_id);

    COMMIT;

    SELECT CAST(1 AS BIT) Success, N'Saved successfully.' Message, @new_id Id;
END;
GO
