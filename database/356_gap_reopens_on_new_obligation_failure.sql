-- =====================================================================
-- 356 Gap Center: an Analysed gap reopens to New when a NEW Obligation
--     fails under the same Practice Instance
--
-- REPORT
-- ------
-- "After a gap is analysed and its status is set to Analysed, the gap
--  status should automatically change to New if any new obligation is
--  marked as not implemented under the practice."
--
-- CURRENT BEHAVIOUR AND WHY IT IS WRONG
-- --------------------------------------------------------------------
-- An Implementation gap is materialized once per Practice Instance
-- (sp_custom_gap_materialize_for_instance, 160/320) and, once analysed,
-- reaches the terminal-valid lifecycle state Delegated -- displayed as
-- "Analysed" (175/319) -- via the auto-Delegate step inside
-- sp_custom_gap_analysis_save (174, carried through 323/324). 324 then
-- deliberately BLOCKS re-analysing that same gap a second time (THROW
-- 55143) -- correct, because nothing about the ALREADY-failing
-- Obligations has changed; re-running the same analysis on the same
-- facts is not meaningful.
--
-- But sp_practice_gap_sync_for_instance (245) -- the proc every
-- Obligation save (bulk adopt AND single local save) already calls,
-- unconditionally, via ResolveWorkspaceService.SyncGapForInstanceAsync
-- -- has never looked at the gap's LIFECYCLE state at all. It only
-- keeps practice_gap / practice_gap_obligation (the Task Center-facing
-- rollup) in step. So today: Instance X has Obligation A failing ->
-- gap materializes -> analyst analyses it -> Delegated ("Analysed").
-- Weeks later Obligation B (a DIFFERENT one, previously fine) on the
-- SAME instance is logged Not Implemented. sync_for_instance correctly
-- adds B as a new practice_gap_obligation child and keeps practice_gap
-- Open -- but the custom_gap Gap Centre actually shows to a user is
-- STILL Delegated/"Analysed", because nothing ever told it Obligation
-- B is a fact the earlier analysis never saw. The gap silently goes
-- stale: it looks resolved in Gap Centre while a genuinely new failure
-- sits underneath it, invisible, with 324's own guard now blocking
-- anyone from re-analysing it (correctly -- if it is still shown as
-- Analysed at all).
--
-- THE FIX
-- -------
-- sp_practice_gap_sync_for_instance is the one place every Obligation
-- save already funnels through (both entry points share it -- see
-- 245's own header), so it is the one place this can be caught for
-- every caller without adding a second hook. Re-issued with:
--
--   1. The existing "3b. Add active children" INSERT now captures,
--      via OUTPUT, exactly which practice_instance_obligation_id rows
--      were genuinely NEW this call -- i.e. entering gap territory for
--      the first time, or re-entering after having been resolved and
--      failing again. An Obligation that was already an Active child
--      (still failing, unchanged, or moved between Not Implemented and
--      Partially Implemented) produces no new row here and triggers
--      nothing -- this is deliberately NOT "any obligation is still
--      failing", only "a new failure just appeared".
--
--   2. After the existing transaction commits (so the Task Center
--      rollup's own correctness is never made to depend on the new
--      step below), IF at least one such new row was captured, look up
--      whether THIS instance already has a materialized custom_gap
--      (source_reference_type='PracticeInstance', source_reference_id
--      = the instance) currently sitting in Delegated. If so, and only
--      then, fire the existing lifecycle engine
--      (sp_custom_gap_lifecycle_transition, 157) with a new action
--      code, ReopenObligation, moving it back to New. Best-effort,
--      like every other post-save gap step this proc and its callers
--      already treat as non-fatal (SyncGapForInstanceAsync itself only
--      logs a warning on failure) -- an obligation save must never fail
--      because the reopen step could not run.
--
--   A gap in New/Validation/Analysis is untouched (nothing to reopen --
--   it is already open). A gap in Invalid/Duplicate is untouched too --
--   deliberately: those are a human's terminal-INVALID verdict on the
--   gap itself ("not real" / "a duplicate"), not a statement about
--   Obligations, and a fresh Obligation failure does not undo that
--   verdict. Only Delegated ("Analysed") is in scope, matching the
--   report exactly.
--
-- WHY A NEW TRANSITION ROW, NOT A DIRECT UPDATE
-- --------------------------------------------------------------------
-- sp_custom_gap_lifecycle_transition (157) is already the single place
-- that mutates custom_gap.lifecycle_state_id + legacy status and writes
-- the custom_gap_history audit row -- every other transition in this
-- codebase (Delegate, MarkInvalid, MarkDuplicate, ...) goes through it
-- rather than a bespoke UPDATE. Reusing it here means this reopen gets
-- the exact same audit trail (custom_gap_history: action_code
-- 'ReopenObligation', from 'Delegated', to 'New') for free, with no
-- duplicated UPDATE/INSERT logic to keep in step with 157's.
--
-- The new (Delegated -> New, 'ReopenObligation') row is seeded ACTIVE,
-- because sp_custom_gap_lifecycle_transition's own validation (line
-- ~182 of 157) requires an Active transition row to allow the action at
-- all -- an Inactive row would be invisible to the ENGINE, not just the
-- UI, since both currently share the same record_status_id filter.
--
-- WHY THIS DOES NOT PUT A NEW BUTTON IN FRONT OF USERS
-- --------------------------------------------------------------------
-- gap-detail.js already has the exact mechanism this needs: an
-- AUTO_ONLY client-side set that hides a fully-Active, fully-valid
-- transition from the manual actions strip because it is meant to fire
-- only from server-side logic -- 'Delegate' itself is hidden this exact
-- way (its transition rows have been Active since 174; only the
-- button is hidden). 'ReopenObligation' is added to that same set (see
-- the accompanying JS change) rather than deactivating the transition
-- row -- deactivating it would also make
-- sp_custom_gap_lifecycle_transition itself refuse the call this
-- migration relies on. Gap Centre's list screen (gaps.cshtml) never
-- calls the actions-list endpoint at all, so it needs no change.
--
-- WHAT THIS DOES NOT DO
--   * Does not touch sp_custom_gap_analysis_save or its 55143 guard --
--     once reopened to New, a fresh analysis is simply a normal first
--     analysis of a gap in the New state, already fully supported.
--   * Does not clear or reset the PRIOR custom_gap_analysis row -- the
--     next analysis save MERGEs onto it exactly as any second save
--     already would, same as before this migration.
--   * Does not touch practice_gap / practice_gap_obligation's own
--     open/close bookkeeping (3a/3c below) -- untouched, still exactly
--     245's behaviour.
--   * Does not affect a gap that has never been materialized (Task
--     Center's practice_gap-only rows) -- there is no custom_gap to
--     reopen, so the lookup in step 2 finds nothing and the proc is a
--     no-op past the existing sync, exactly as before this migration.
--
-- SCOPE
--   1. gap_lifecycle_transition_master -- + 1 row: Delegated -> New,
--      action_code = 'ReopenObligation'.
--   2. sp_practice_gap_sync_for_instance -- re-issued from 245's exact
--      body: OUTPUT capture on the existing INSERT, + the new
--      best-effort reopen step after COMMIT.
--
-- No new error codes (no new THROW added -- the reopen step is
-- best-effort and never raises past this proc, matching this proc's
-- own existing tolerance for a failed downstream step).
--
-- Re-runnable: yes (seed is NOT EXISTS-guarded; proc is CREATE OR ALTER).
-- Rollback: database/356_gap_reopens_on_new_obligation_failure_rollback.sql
-- DEPENDS ON: 156/157/158 (lifecycle engine), 174 (Delegated state), 245
--             (practice_gap / sp_practice_gap_sync_for_instance).
-- ASCII-only on purpose (sqlcmd codepage safety).
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

DECLARE @ok BIT = 1;
IF SCHEMA_ID('grac_practice') IS NULL
BEGIN PRINT 'ABORT (356): schema grac_practice missing.'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.sp_practice_gap_sync_for_instance','P') IS NULL
BEGIN PRINT 'ABORT (356): sp_practice_gap_sync_for_instance missing (run 245 first).'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.sp_custom_gap_lifecycle_transition','P') IS NULL
BEGIN PRINT 'ABORT (356): sp_custom_gap_lifecycle_transition missing (run 157 first).'; SET @ok = 0; END
IF NOT EXISTS (SELECT 1 FROM grac_practice.gap_lifecycle_state_master WHERE state_code = N'Delegated')
BEGIN PRINT 'ABORT (356): lifecycle state Delegated missing (run 174 first).'; SET @ok = 0; END
IF NOT EXISTS (SELECT 1 FROM grac_practice.gap_lifecycle_state_master WHERE state_code = N'New')
BEGIN PRINT 'ABORT (356): lifecycle state New missing (run 158 first).'; SET @ok = 0; END
IF @ok = 0
BEGIN
    RAISERROR('356_gap_reopens_on_new_obligation_failure: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. New transition: Delegated -> New, action_code = 'ReopenObligation'
--
-- Active (not Inactive) -- see the header note above for why: the
-- lifecycle engine's own validation shares the same Active filter the
-- UI's action list uses, so an Inactive row would silently block this
-- migration's own reopen call, not just hide a button.
-- =====================================================================
DECLARE @active_rs INT = (SELECT record_status_id FROM grac_practice.record_status_master WHERE status_code = N'Active');
IF @active_rs IS NULL
BEGIN
    PRINT 'ABORT (356): record_status_master.Active missing.';
    RAISERROR('356_gap_reopens_on_new_obligation_failure: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

DECLARE @active_rs INT = (SELECT record_status_id FROM grac_practice.record_status_master WHERE status_code = N'Active');
DECLARE @s_del     INT = (SELECT lifecycle_state_id FROM grac_practice.gap_lifecycle_state_master WHERE state_code = N'Delegated');
DECLARE @s_new     INT = (SELECT lifecycle_state_id FROM grac_practice.gap_lifecycle_state_master WHERE state_code = N'New');

IF NOT EXISTS (
    SELECT 1 FROM grac_practice.gap_lifecycle_transition_master
     WHERE from_state_id = @s_del AND action_code = N'ReopenObligation')
    INSERT INTO grac_practice.gap_lifecycle_transition_master
        (from_state_id, to_state_id, action_code, action_name, description, remark_required,
         record_status_id, entered_by, entered_dt)
    VALUES
        (@s_del, @s_new, N'ReopenObligation', N'Reopen (New Obligation Failure)',
         N'System-fired only: a new Obligation was logged Not Implemented / Partially '
         + N'Implemented under this Practice Instance after the gap had already been '
         + N'analysed. Hidden from the manual actions strip (gap-detail.js AUTO_ONLY), '
         + N'exactly like Delegate.',
         0, @active_rs, N'seed-356', SYSUTCDATETIME());
GO
PRINT '356: gap_lifecycle_transition_master has Delegated -> New / ReopenObligation.';
GO

-- =====================================================================
-- 2. sp_practice_gap_sync_for_instance -- re-issued from 245's exact
--    body, plus OUTPUT capture on the 3b INSERT and the new reopen step.
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
            -- T-SQL: EXEC parameters can't take expressions (same note
            -- 174's sp_custom_gap_task_create left on @task_title) --
            -- precompute the remark before the call.
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
                -- Never lets an obligation save fail over this. 55105
                -- ("action is not allowed from the current state") would
                -- mean this migration's own transition row is missing or
                -- inactive on this database -- surfaced here as a
                -- warning rather than silently swallowed.
                PRINT CONCAT(N'sp_practice_gap_sync_for_instance: auto-reopen warning: ', ERROR_MESSAGE());
            END CATCH
        END
    END

    -- Small result set so the API tier can log the outcome. Unchanged
    -- from 245.
    SELECT @practice_instance_id  AS PracticeInstanceId,
           @practice_gap_id       AS PracticeGapId,
           (SELECT gap_status FROM grac_practice.practice_gap
             WHERE practice_gap_id = @practice_gap_id) AS GapStatus,
           (SELECT COUNT(*) FROM grac_practice.practice_gap_obligation
             WHERE practice_gap_id = @practice_gap_id AND status = N'Active') AS ActiveObligationCount;
END
GO
PRINT '356: sp_practice_gap_sync_for_instance now auto-reopens an Analysed gap on a new Obligation failure.';
GO

-- =====================================================================
-- Verification
-- =====================================================================
PRINT '=== 356 verification ===';

DECLARE @def NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_practice_gap_sync_for_instance','P'));

SELECT '356-a Delegated -> New / ReopenObligation transition exists and is Active' AS Check_,
       CASE WHEN EXISTS (
                SELECT 1
                  FROM grac_practice.gap_lifecycle_transition_master t
                  JOIN grac_practice.gap_lifecycle_state_master fs ON fs.lifecycle_state_id = t.from_state_id
                  JOIN grac_practice.gap_lifecycle_state_master ts ON ts.lifecycle_state_id = t.to_state_id
                  JOIN grac_practice.record_status_master r        ON r.record_status_id    = t.record_status_id
                 WHERE fs.state_code = N'Delegated'
                   AND ts.state_code = N'New'
                   AND t.action_code = N'ReopenObligation'
                   AND r.status_code = N'Active')
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '356-b sync proc still present',
       CASE WHEN @def IS NOT NULL THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '356-c sync proc captures newly-added obligations via OUTPUT',
       CASE WHEN @def LIKE '%OUTPUT inserted.practice_instance_obligation_id INTO @newly_added%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '356-d sync proc fires the reopen only for Delegated gaps',
       CASE WHEN @def LIKE '%s.state_code             = N''Delegated''%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '356-e sync proc calls the lifecycle engine with ReopenObligation',
       CASE WHEN @def LIKE '%sp_custom_gap_lifecycle_transition%'
             AND @def LIKE '%N''ReopenObligation''%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '356-f original 3a/3c retire+close/open logic untouched',
       CASE WHEN @def LIKE '%SET status     = N''Retired''%'
             AND @def LIKE '%SET gap_status = N''Closed''%'
             AND @def LIKE '%SET gap_status  = N''Open''%'
            THEN 'PASS' ELSE 'FAIL' END;

PRINT '';
PRINT '--- Diagnostic: currently-Delegated (Analysed) Implementation gaps and how many';
PRINT '    Active failed-obligation rows sit under each one right now ---';
SELECT cg.custom_gap_id, cg.title, pi.instance_code,
       (SELECT COUNT(*) FROM grac_practice.practice_gap pg
          JOIN grac_practice.practice_gap_obligation pgo
               ON pgo.practice_gap_id = pg.practice_gap_id AND pgo.status = N'Active'
         WHERE pg.practice_instance_id = cg.source_reference_id) AS ActiveFailedObligationCount
  FROM grac_practice.custom_gap cg
  JOIN grac_practice.gap_lifecycle_state_master s ON s.lifecycle_state_id = cg.lifecycle_state_id
  LEFT JOIN grac_practice.practice_instance pi
         ON pi.practice_instance_id = cg.source_reference_id
        AND cg.source_reference_type = N'PracticeInstance'
 WHERE s.state_code = N'Delegated'
   AND cg.gap_source_module_code = N'Implementation'
 ORDER BY cg.custom_gap_id DESC;

PRINT '';
PRINT 'A nonzero ActiveFailedObligationCount above on an already-Delegated gap means';
PRINT 'it went stale BEFORE this migration ran (its own analysis save happened before';
PRINT 'the obligation that is failing now). This migration only changes behaviour';
PRINT 'going forward -- it does not retroactively reopen gaps that were already stale';
PRINT 'when it was applied, since nothing here re-runs the sync for every instance.';
PRINT 'The next obligation save on any of these instances will reopen them, or an';
PRINT 'operator can re-run sp_practice_gap_sync_for_instance by hand per instance id';
PRINT 'above if an immediate reopen is wanted.';

PRINT '';
PRINT '356 complete. An Analysed (Delegated) Implementation gap now reopens to New';
PRINT 'the moment a new Obligation is logged Not Implemented / Partially Implemented';
PRINT 'under the same Practice Instance, on every save path, with a full audit row';
PRINT 'in custom_gap_history. No C#/JS rebuild is required for the database side --';
PRINT 'the client-side action-hiding change is JS-only (gap-detail.js), and reuses';
PRINT 'the same AUTO_ONLY mechanism already shipped for Delegate/Validate.';
GO

SET NOEXEC OFF;
GO
