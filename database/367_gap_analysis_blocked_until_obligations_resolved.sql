-- =====================================================================
-- 367 Gap Center / Gap Analysis: a gap shows every unresolved Obligation
--     under its Practice, and Analysis is blocked until all of them are
--     resolved AND the Practice is Operationalized
--
-- REQUEST
-- -------
-- "Currently, when an obligation is marked Not Implemented, a gap is
--  created. However: only the specific Not Implemented obligation is
--  displayed under the gap; the gap can be analysed immediately; if
--  another obligation under the same practice is later marked Not
--  Implemented, the gap becomes newly generated/reopens and the
--  analysis status changes again."
--
-- Required behaviour:
--   1. Create a gap when any obligation under a Practice is Not
--      Implemented (unchanged from today).
--   2. Once created, the gap displays every obligation under that
--      Practice EXCEPT those already Implemented -- i.e. Not
--      Implemented, Not Set (Not Started), and Partially Implemented,
--      not only the one obligation that triggered creation.
--   3. Gap Analysis is blocked while any obligation displayed under the
--      gap is unresolved (including Not Set).
--   4. Gap Analysis is allowed only once the related Practice has been
--      Operationalized, per the existing business rule -- confirmed by
--      the user to be the LIVE dependency-resolution computation
--      already shown as "Operationalized" on the Repository/Register
--      screens and the Practice page (ResolvedDependenciesCount >=
--      TotalDependencyCategories, with at least one category
--      configured), NOT the dormant, never-written practice_
--      operationalization table.
--
-- ROOT CAUSE
-- --------------------------------------------------------------------
-- sp_practice_gap_sync_for_instance (245, re-issued unchanged-in-shape
-- by 356) is the single place every Obligation save (bulk adopt AND
-- single local save, via ResolveWorkspaceService.SyncGapForInstanceAsync)
-- already funnels through. Its @current set -- which becomes both "does
-- a gap exist" (the creation gate) and "which obligations are Active
-- children under it" (what gap-detail's Failed Obligations strip and
-- Task Center's LinkedCount both read) -- has always been populated by
-- an INNER JOIN to implementation_status_master filtered
-- status_code IN ('Not Implemented','Partially Implemented'). An INNER
-- JOIN structurally drops any obligation whose implementation_status_id
-- is NULL (the user's "Not Set", DB's "Not Started" per 243's rank
-- vocabulary) -- it can never appear in @current, so it can never become
-- an Active practice_gap_obligation child, no matter how the gap logic
-- around it changes. That is why today's gap shows only the ONE
-- obligation that triggered it: every OTHER obligation on the same
-- instance that happens to be Not Started is invisible to this proc by
-- construction, and Gap Analysis has never had anything checking
-- obligation completeness or Practice Operationalization at all.
--
-- THE FIX
-- --------------------------------------------------------------------
-- sp_practice_gap_sync_for_instance -- re-issued from 356's exact body
-- with @current split into two sets:
--   * @current (broadened): LEFT JOIN + COALESCE(status_code,'Not
--     Started'), filtered NOT IN ('Implemented','N/A') -- i.e. every
--     obligation that is not yet Implemented and not N/A (N/A is
--     excluded from all rollups system-wide per 243). This is
--     requirement #2's "all obligations displayed under the gap" and
--     now drives the existing 3a/3b/3c retire/add/recompute logic
--     completely unchanged in shape -- so gap-detail's Failed
--     Obligations strip and Task Center's counts broaden automatically,
--     with no changes needed to either of those queries (317, 243).
--   * @gap_trigger (unchanged scope): Not Implemented / Partially
--     Implemented only -- exactly @current's old, narrower filter. This
--     alone gates the parent practice_gap INSERT, so requirement #1
--     ("create gap when Not Implemented") is preserved exactly as it
--     works today: a Practice with only Not Started obligations (no
--     Implemented, no Not Implemented, no Partially Implemented) still
--     creates no gap at all -- consistent with sp_task_center_gaps_list
--     (243) and sp_custom_gap_materialize_for_instance (160), neither
--     of which is touched by this migration and both of which stay
--     scoped to the same narrow trigger.
--
-- sp_custom_gap_analysis_save -- re-issued from 324's exact body with
-- two new guards, inserted immediately after the existing terminal-
-- invalid (173/55142) and re-analysis (324/55143) guards, and scoped
-- ONLY to a gap materialized from a Practice Instance
-- (gap_source_module_code = 'Implementation' AND source_reference_type
-- = 'PracticeInstance') -- a Custom/Assurance/Exception/Risk-sourced gap
-- is untouched, exactly as today:
--   * 55144 -- at least one Active practice_gap_obligation child remains
--     under this instance's practice_gap (i.e. an obligation currently
--     displayed under the gap is still Not Implemented / Partially
--     Implemented / Not Started). Reads practice_gap_obligation rather
--     than recomputing from practice_instance_obligation directly,
--     because that table IS "what is currently displayed under the
--     gap" (kept in step by sp_practice_gap_sync_for_instance on every
--     obligation save) -- the same source gap-detail's Failed
--     Obligations strip already reads from (317).
--   * 55145 -- the Practice Instance is not yet Operationalized, using
--     the exact TotalDependencyCategories / ResolvedDependenciesCount
--     computation duplicated in dbo.pm_get_practice_repository and
--     PracticeRepositoryService.cs's QueryResolveFallbackAsync (the
--     rule the user confirmed): Operationalized only when at least one
--     dependency category is configured AND every configured category
--     has a resolution recorded.
--
-- sp_custom_gap_header -- re-issued from 325's exact body with one new
-- additive column, IsPracticeOperationalized (BIT, NULL when there is
-- no linked Practice Instance), using the identical computation as the
-- new 55145 guard -- so gap-detail.js can show an "awaiting
-- Operationalization" reason on its blocked-banner without a second
-- round trip, and so the two never drift apart from each other.
--
-- WHY THIS SATISFIES THE "IMPORTANT GAP LIFECYCLE BEHAVIOUR" NOTE
-- --------------------------------------------------------------------
-- "Once a gap is generated for a practice, do not treat each newly
-- failing obligation as a completely separate analysis cycle... the gap
-- should represent the current unresolved obligation state of that
-- practice." This is exactly what sp_practice_gap_sync_for_instance
-- already does, unchanged in shape by this migration -- ONE practice_gap
-- row per practice_instance_id (UNIQUE, 245), continuously kept in step
-- with the instance's live obligation set on every save. Broadening
-- @current does not create a second gap or a new analysis cycle for a
-- newly-Not-Started obligation; it simply adds one more Active child to
-- the SAME gap row, which 356's own reopen-on-new-failure logic (already
-- keyed off exactly this INSERT's OUTPUT) already treats as "the same
-- gap, now with one more thing to resolve" -- not a new gap.
--
-- WHAT THIS DOES NOT DO
--   * Does not change what CREATES a gap (still Not Implemented /
--     Partially Implemented only -- see @gap_trigger above).
--   * Does not change sp_custom_gap_materialize_for_instance (160) or
--     sp_task_center_gaps_list (243) -- neither has, or needs, its own
--     obligation-status gating; the Task Center "Analysis" affordance
--     stays scoped to the same narrow trigger it always has been.
--   * Does not touch the practice_operationalization table or its
--     never-populated 'Resolved' join predicate (rejected candidate --
--     see the migration's design discussion) -- this migration only
--     reads the live dependency-resolution CTEs, exactly as the
--     Repository/Register screens already do, never that table.
--   * Does not add a THROW for a Custom/Assurance/Exception/Risk gap --
--     both new guards are scoped strictly to gap_source_module_code =
--     'Implementation' AND source_reference_type = 'PracticeInstance'.
--
-- SCOPE
--   1. sp_practice_gap_sync_for_instance -- re-issued from 356.
--   2. sp_custom_gap_analysis_save       -- re-issued from 324, + 55144 /
--                                            55145 guards.
--   3. sp_custom_gap_header              -- re-issued from 325, +
--                                            IsPracticeOperationalized.
--
-- No schema change. No data migration -- an already-Delegated gap whose
-- Practice now has a broadened set of unresolved obligations is not
-- retroactively reopened by this migration alone (same caveat 356's own
-- header already documents); the next Obligation save on that instance
-- reopens it via the existing 356 mechanism, unchanged here.
--
-- Rollback: 367_gap_analysis_blocked_until_obligations_resolved_rollback.sql
-- (restores all three procs to their exact pre-367 bodies: sp_practice_
-- gap_sync_for_instance to 356's, sp_custom_gap_analysis_save to 324's,
-- sp_custom_gap_header to 325's).
--
-- Depends on: 243 (implementation status rank/vocabulary), 245/356
-- (practice_gap / sp_practice_gap_sync_for_instance), 324 (sp_custom_
-- gap_analysis_save), 325 (sp_custom_gap_header), the dependency /
-- resolution tables used by dbo.pm_get_practice_repository (002).
-- SAFE TO RE-RUN. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

DECLARE @ok BIT = 1;
IF SCHEMA_ID('grac_practice') IS NULL
BEGIN PRINT 'ABORT (367): schema grac_practice missing.'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.sp_practice_gap_sync_for_instance','P') IS NULL
BEGIN PRINT 'ABORT (367): sp_practice_gap_sync_for_instance missing (run 245/356 first).'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.sp_custom_gap_analysis_save','P') IS NULL
BEGIN PRINT 'ABORT (367): sp_custom_gap_analysis_save missing (run 324 first).'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.sp_custom_gap_header','P') IS NULL
BEGIN PRINT 'ABORT (367): sp_custom_gap_header missing (run 325 first).'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.practice_instance_dependency','U') IS NULL
BEGIN PRINT 'ABORT (367): practice_instance_dependency missing.'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.practice_dependency_resolution','U') IS NULL
BEGIN PRINT 'ABORT (367): practice_dependency_resolution missing.'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.practice_gap_obligation','U') IS NULL
BEGIN PRINT 'ABORT (367): practice_gap_obligation missing (run 245 first).'; SET @ok = 0; END
IF @ok = 0
BEGIN
    RAISERROR('367_gap_analysis_blocked_until_obligations_resolved: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. sp_practice_gap_sync_for_instance -- re-issued from 356's exact
--    body. Only change: @current is broadened (LEFT JOIN + COALESCE,
--    NOT IN Implemented/N/A) and a separate, narrower @gap_trigger
--    (unchanged old filter) now gates the parent practice_gap INSERT.
--    3a/3b/3c and the post-commit reopen step are otherwise untouched.
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

    -- 367: every obligation under this instance that is not yet
    -- Implemented and not N/A -- Not Implemented, Partially Implemented,
    -- In Progress, and Not Set/Not Started (NULL implementation_
    -- status_id, never dropped now that this is a LEFT JOIN). This is
    -- "all obligations displayed under the gap" (requirement #2) and
    -- drives 3a/3b/3c below exactly as the old, narrower @current did.
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
           COALESCE(ims.status_code, N'Not Started')
    FROM   grac_practice.practice_instance_obligation pio
    LEFT   JOIN grac_practice.implementation_status_master ims
           ON ims.implementation_status_id = pio.implementation_status_id
    WHERE  pio.practice_instance_id = @practice_instance_id
      AND  pio.status               = N'Active'
      AND  COALESCE(ims.status_code, N'Not Started') NOT IN (N'Implemented', N'N/A');

    -- 367: the parent-gap CREATION trigger stays exactly as narrow as it
    -- was before this migration -- requirement #1 is explicit that a gap
    -- is created "when any obligation is Not Implemented"; broadening
    -- @current above must not also broaden what creates the gap.
    DECLARE @gap_trigger TABLE (practice_instance_obligation_id BIGINT PRIMARY KEY);
    INSERT INTO @gap_trigger (practice_instance_obligation_id)
    SELECT practice_instance_obligation_id
    FROM   @current
    WHERE  status_code IN (N'Not Implemented', N'Partially Implemented');

    -- 356: which practice_instance_obligation_id rows are genuinely NEW
    -- to the gap this call (captured via OUTPUT on the 3b INSERT below).
    -- Read AFTER the transaction commits to decide whether to fire the
    -- reopen step -- deliberately not "any obligation is still failing",
    -- only "a failure that was not there a moment ago just appeared".
    -- 367 note: with @current broadened, a newly-added Not Started
    -- obligation now also counts as "newly added" here -- consistent
    -- with the requirement that the gap represent the practice's CURRENT
    -- unresolved-obligation state, not just its Not-Implemented state.
    DECLARE @newly_added TABLE (practice_instance_obligation_id BIGINT PRIMARY KEY);

    BEGIN TRAN;

    -- Ensure the parent row exists. Insert only when there is at least
    -- one obligation that actually TRIGGERS a gap (367: @gap_trigger,
    -- not the broadened @current) -- do not create a gap for a Practice
    -- whose only unresolved obligations are Not Started.
    IF NOT EXISTS (SELECT 1 FROM grac_practice.practice_gap
                    WHERE practice_instance_id = @practice_instance_id)
       AND EXISTS (SELECT 1 FROM @gap_trigger)
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
    --     AND "obligation was retired from the instance". Unchanged
    --     logic -- now checks against the broadened @current.
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
    --     when the row is there. OUTPUT captures exactly which
    --     obligation ids this INSERT actually added, so the reopen step
    --     below can tell "a new failure just appeared" from "the same
    --     ones are still failing". Unchanged logic -- now inserts from
    --     the broadened @current, so a Not Started obligation becomes a
    --     child too (requirement #2).
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
        --     any active row exists. Unchanged.
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
    -- new Obligation entered gap territory above (367: now includes a
    -- newly Not Started obligation, not only a newly Not Implemented
    -- one -- see the header note above). Runs after the practice_gap/
    -- practice_gap_obligation transaction has already committed, and is
    -- best-effort -- an Obligation save must never fail because this
    -- step could not run, exactly the same tolerance this proc's own
    -- caller (ResolveWorkspaceService.SyncGapForInstanceAsync) already
    -- applies to this whole procedure.
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
            DECLARE @reopen_remark NVARCHAR(MAX) = N'Auto-reopened: a new Obligation entered this '
                + N'gap''s unresolved set (Not Implemented / Partially '
                + N'Implemented / Not Started) under this Practice '
                + N'Instance after the gap had already been analysed.';
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
    -- from 245/356.
    SELECT @practice_instance_id  AS PracticeInstanceId,
           @practice_gap_id       AS PracticeGapId,
           (SELECT gap_status FROM grac_practice.practice_gap
             WHERE practice_gap_id = @practice_gap_id) AS GapStatus,
           (SELECT COUNT(*) FROM grac_practice.practice_gap_obligation
             WHERE practice_gap_id = @practice_gap_id AND status = N'Active') AS ActiveObligationCount;
END
GO
PRINT '367: sp_practice_gap_sync_for_instance now shows every unresolved obligation under the gap.';
GO

-- =====================================================================
-- 2. sp_custom_gap_analysis_save -- re-issued from 324's exact body,
--    plus two new guards for a Practice-Instance-sourced gap: unresolved
--    obligations (55144) and not-yet-Operationalized (55145). Inserted
--    right after the existing terminal-invalid (55142) and re-analysis
--    (55143) guards; everything else (MERGE, auto-triggers, auto-
--    delegate) is byte-for-byte unchanged from 324.
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

    -- Migration 324: terminal-VALID guard -- the missing counterpart to
    -- 173's guard above. Blocks re-analysis once the gap has already
    -- reached Delegated/"Analysed" (is_terminal = 1 AND is_valid_terminal
    -- = 1). A gap that has never been through the lifecycle yet has
    -- lifecycle_state_id = NULL, which this LEFT JOIN + IS NULL check
    -- never matches -- a first analysis is not blocked by this guard.
    IF EXISTS (
        SELECT 1
          FROM grac_practice.custom_gap g
          LEFT JOIN grac_practice.gap_lifecycle_state_master s ON s.lifecycle_state_id = g.lifecycle_state_id
         WHERE g.custom_gap_id = @custom_gap_id
           AND s.is_terminal = 1 AND s.is_valid_terminal = 1)
        THROW 55143, 'sp_custom_gap_analysis_save: this gap has already been analysed; re-analysis is not allowed. Open it in View mode to see the saved analysis.', 1;

    -- =================================================================
    -- Migration 367: for a gap materialized from a Practice Instance
    -- (Implementation source), Analysis is blocked until (a) every
    -- obligation currently displayed under the gap is resolved and
    -- (b) the Practice Instance has been Operationalized. Scoped
    -- strictly to gap_source_module_code = 'Implementation' AND
    -- source_reference_type = 'PracticeInstance' -- a Custom/Assurance/
    -- Exception/Risk-sourced gap is never subject to either guard.
    -- =================================================================
    DECLARE @src_module NVARCHAR(30), @src_type NVARCHAR(60), @src_instance_id BIGINT;
    SELECT @src_module      = g.gap_source_module_code,
           @src_type        = g.source_reference_type,
           @src_instance_id = g.source_reference_id
      FROM grac_practice.custom_gap g
     WHERE g.custom_gap_id = @custom_gap_id;

    IF @src_module = N'Implementation' AND @src_type = N'PracticeInstance' AND @src_instance_id IS NOT NULL
    BEGIN
        -- (a) at least one obligation currently displayed under the gap
        -- (an Active practice_gap_obligation child -- the same set
        -- gap-detail's Failed/Unresolved Obligations strip already
        -- reads via sp_custom_gap_linked_artefacts, 317, and that 367's
        -- broadened sp_practice_gap_sync_for_instance keeps in step on
        -- every obligation save) is still unresolved.
        IF EXISTS (
            SELECT 1
              FROM grac_practice.practice_gap pg
              JOIN grac_practice.practice_gap_obligation pgo
                   ON pgo.practice_gap_id = pg.practice_gap_id
                  AND pgo.status          = N'Active'
             WHERE pg.practice_instance_id = @src_instance_id)
            THROW 55144, 'sp_custom_gap_analysis_save: one or more obligations displayed under this gap are still unresolved (Not Implemented / Partially Implemented / Not Set); resolve them before this gap can be analysed.', 1;

        -- (b) the Practice Instance must be Operationalized. Same live
        -- dependency-resolution computation as dbo.pm_get_practice_
        -- repository / PracticeRepositoryService.QueryResolveFallbackAsync
        -- (the rule the user confirmed) -- never the dormant practice_
        -- operationalization table.
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

    -- Still validated if a caller passes one, but no longer required and
    -- no longer used to compute @recommend_task/@recommend_exception/
    -- @recommend_risk (migration 323 -- see header).
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

    -- Mirror severity onto the gap itself so existing severity-based
    -- filters keep working. Only overwrite when the caller passed one.
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

    -- ============ Auto-trigger: Task (recommend_task = 1) =============
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

    -- ============ Auto-trigger: Exception request ======================
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

    -- ============ Auto-trigger: Risk candidate =========================
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

    -- ============ Auto-transition to Delegated ========================
    -- 324 fix: LEFT JOIN + NULL treated as 'New' (see 324's header --
    -- the INNER JOIN this block used from 174 through 323 silently
    -- skipped the whole block for any gap with a NULL lifecycle_state_id,
    -- which is why the status never reached Analysed). Outcome captured
    -- instead of only PRINTed.
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

    -- Fresh post-transition state (whether or not the block above ran or
    -- succeeded) -- read once, after every write above, so the second
    -- result set reports what the database actually holds now.
    DECLARE @final_state_code NVARCHAR(60), @final_state_name NVARCHAR(120);
    SELECT @final_state_code = s.state_code, @final_state_name = s.state_name
      FROM grac_practice.custom_gap g
      LEFT JOIN grac_practice.gap_lifecycle_state_master s ON s.lifecycle_state_id = g.lifecycle_state_id
     WHERE g.custom_gap_id = @custom_gap_id;
    IF @final_state_code IS NULL SET @final_state_code = N'New';
    IF @final_state_name IS NULL SET @final_state_name = N'New';

    -- The API opens a reader on this proc; keep the result set.
    SELECT @custom_gap_id AS CustomGapId;

    SELECT
        @task_created      AS TaskCreated,      @task_error      AS TaskError,
        @exception_created AS ExceptionCreated, @exception_error AS ExceptionError,
        @risk_created      AS RiskCreated,      @risk_error      AS RiskError,
        @lifecycle_transitioned AS LifecycleTransitioned, @lifecycle_error AS LifecycleError,
        @final_state_code       AS LifecycleStateCode,    @final_state_name AS LifecycleStateName;
END
GO
PRINT '367: sp_custom_gap_analysis_save now blocks analysis until obligations are resolved and the Practice is Operationalized.';
GO

-- =====================================================================
-- 3. sp_custom_gap_header -- re-issued from 325's exact body, plus one
--    new additive column, IsPracticeOperationalized, computed with the
--    identical rule as the new 55145 guard above. NULL when there is no
--    linked Practice Instance (Custom/Assurance/Exception/Risk gaps).
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
        -- Migration 250: exposed on the header so the analysis form
        -- can pre-populate "auto" fields from the values the operator
        -- entered at Add Gap. Nullable -- absent on non-Custom gaps
        -- and on legacy rows.
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
        -- Migration 321: which Practice Instance (if any) materialized
        -- this gap.
        pi.practice_instance_id    AS PracticeInstanceId,
        pi.instance_code           AS PracticeInstanceCode,
        pi.instance_name           AS PracticeInstanceName,
        -- Migration 325: when the gap was identified/raised. Same value
        -- Gap Centre's own list already sorts new gaps by (entered_dt),
        -- simply not projected on the header until now. NULL only for a
        -- pre-existing legacy row that predates entered_dt being stamped
        -- at all.
        g.entered_dt                AS IdentifiedDate,
        -- Migration 367: whether the linked Practice Instance is
        -- currently Operationalized -- NULL when there is none (Custom/
        -- Assurance/Exception/Risk gaps). Same live dependency-
        -- resolution rule as the 55145 guard in sp_custom_gap_analysis_
        -- save and as dbo.pm_get_practice_repository /
        -- PracticeRepositoryService.QueryResolveFallbackAsync.
        CASE
            WHEN pi.practice_instance_id IS NULL THEN NULL
            WHEN pi.status IN (N'Inactive', N'Retired') OR pirs.status_code IN (N'Inactive', N'Retired') THEN CAST(0 AS BIT)
            WHEN ISNULL(dep.TotalDependencyCategories, 0) = 0 THEN CAST(0 AS BIT)
            WHEN ISNULL(res.ResolvedDependenciesCount, 0) >= ISNULL(dep.TotalDependencyCategories, 0) THEN CAST(1 AS BIT)
            ELSE CAST(0 AS BIT)
        END                          AS IsPracticeOperationalized
      FROM grac_practice.custom_gap g
 LEFT JOIN grac_practice.gap_lifecycle_state_master s ON s.lifecycle_state_id = g.lifecycle_state_id
 LEFT JOIN grac_practice.custom_gap p                 ON p.custom_gap_id      = g.duplicate_of_gap_id
 LEFT JOIN grac_practice.practice_instance pi          ON pi.practice_instance_id = g.source_reference_id
                                                       AND g.source_reference_type = N'PracticeInstance'
                                                       AND pi.organization_id      = g.organization_id
 LEFT JOIN grac_practice.record_status_master pirs     ON pirs.record_status_id   = pi.record_status_id
 OUTER APPLY (SELECT COUNT(DISTINCT d.dependency_type_id) AS TotalDependencyCategories
                FROM grac_practice.practice_instance_dependency d
               WHERE d.practice_instance_id = pi.practice_instance_id
                 AND d.status               = N'Active'
                 AND d.dependency_type_id  IS NOT NULL) dep
 OUTER APPLY (SELECT COUNT(*) AS ResolvedDependenciesCount
                FROM grac_practice.practice_dependency_resolution r
               WHERE r.practice_instance_id = pi.practice_instance_id
                 AND r.is_active            = 1) res
     WHERE g.custom_gap_id = @custom_gap_id;
END
GO
PRINT '367: sp_custom_gap_header now projects IsPracticeOperationalized.';
GO

-- =====================================================================
-- Verification
-- =====================================================================
PRINT '=== 367 verification ===';

DECLARE @sync NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_practice_gap_sync_for_instance','P'));
DECLARE @ansv NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_custom_gap_analysis_save','P'));
DECLARE @hdr  NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_custom_gap_header','P'));

SELECT '367-a sync proc broadens @current to a LEFT JOIN with Not Started coalesced in' AS Check_,
       CASE WHEN @sync LIKE '%LEFT%JOIN%grac_practice.implementation_status_master ims%'
             AND @sync LIKE '%COALESCE(ims.status_code, N''Not Started'')%'
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '367-b sync proc excludes only Implemented / N/A from @current',
       CASE WHEN @sync LIKE '%NOT IN (N''Implemented'', N''N/A'')%' THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '367-c sync proc gates gap CREATION on the narrower @gap_trigger, not @current',
       CASE WHEN @sync LIKE '%EXISTS (SELECT 1 FROM @gap_trigger)%'
             AND @sync LIKE '%status_code IN (N''Not Implemented'', N''Partially Implemented'')%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '367-d sync proc 3a/3b/3c retire+add+close/open logic still present (245/356 regression check)',
       CASE WHEN @sync LIKE '%SET status     = N''Retired''%'
             AND @sync LIKE '%OUTPUT inserted.practice_instance_obligation_id INTO @newly_added%'
             AND @sync LIKE '%SET gap_status = N''Closed''%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '367-e sync proc still fires the 356 auto-reopen on new obligations',
       CASE WHEN @sync LIKE '%sp_custom_gap_lifecycle_transition%' AND @sync LIKE '%N''ReopenObligation''%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '367-f analysis_save has the new unresolved-obligations guard (55144)',
       CASE WHEN @ansv LIKE '%55144%' AND @ansv LIKE '%practice_gap_obligation%' THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '367-g analysis_save has the new not-Operationalized guard (55145)',
       CASE WHEN @ansv LIKE '%55145%' AND @ansv LIKE '%@is_operationalized = 0%' THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '367-h analysis_save scopes both new guards to Implementation/PracticeInstance gaps only',
       CASE WHEN @ansv LIKE '%@src_module = N''Implementation'' AND @src_type = N''PracticeInstance''%' THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '367-i analysis_save still guards terminal-invalid (173/55142) and re-analysis (324/55143)',
       CASE WHEN @ansv LIKE '%55142%' AND @ansv LIKE '%55143%' THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '367-j analysis_save still returns CustomGapId + Lifecycle* result set (324 regression check)',
       CASE WHEN @ansv LIKE '%AS CustomGapId%' AND @ansv LIKE '%AS LifecycleStateCode%' THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '367-k header proc now projects IsPracticeOperationalized',
       CASE WHEN @hdr LIKE '%IsPracticeOperationalized%' THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '367-l header proc still projects IdentifiedDate (325 regression check)',
       CASE WHEN @hdr LIKE '%IdentifiedDate%' THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '367-m header proc still projects PracticeInstanceId (321 regression check)',
       CASE WHEN @hdr LIKE '%PracticeInstanceId%' THEN 'PASS' ELSE 'FAIL' END;

PRINT '';
PRINT '--- Diagnostic: open practice_gap rows and how many obligations now sit under';
PRINT '    each one, broken down by the status that put them there ---';
SELECT pg.practice_gap_id, pi.instance_code, pi.instance_name,
       pg.gap_status,
       SUM(CASE WHEN pgo.logged_status_code = N'Not Implemented'       THEN 1 ELSE 0 END) AS NotImplementedCount,
       SUM(CASE WHEN pgo.logged_status_code = N'Partially Implemented' THEN 1 ELSE 0 END) AS PartiallyImplementedCount,
       SUM(CASE WHEN pgo.logged_status_code = N'Not Started'           THEN 1 ELSE 0 END) AS NotStartedCount,
       SUM(CASE WHEN pgo.logged_status_code NOT IN (N'Not Implemented', N'Partially Implemented', N'Not Started') THEN 1 ELSE 0 END) AS OtherCount
  FROM grac_practice.practice_gap pg
  JOIN grac_practice.practice_instance pi ON pi.practice_instance_id = pg.practice_instance_id
  LEFT JOIN grac_practice.practice_gap_obligation pgo
         ON pgo.practice_gap_id = pg.practice_gap_id AND pgo.status = N'Active'
 WHERE pg.gap_status = N'Open'
 GROUP BY pg.practice_gap_id, pi.instance_code, pi.instance_name, pg.gap_status
 ORDER BY pg.practice_gap_id DESC;

PRINT '';
PRINT 'A nonzero NotStartedCount above on a row that existed before this migration ran';
PRINT 'means that Practice had Not Started obligations invisible to the gap until now';
PRINT '-- they will appear as Active children (and factor into the 55144 guard) the';
PRINT 'next time sp_practice_gap_sync_for_instance runs for that instance (any';
PRINT 'obligation save), or immediately if an operator re-runs it by hand.';

PRINT '';
PRINT '--- Diagnostic: currently-Delegated (Analysed) Implementation gaps and their';
PRINT '    Practice Instance''s current Operationalization status ---';
SELECT cg.custom_gap_id, cg.title, pi.instance_code,
       (SELECT COUNT(DISTINCT d.dependency_type_id) FROM grac_practice.practice_instance_dependency d
         WHERE d.practice_instance_id = pi.practice_instance_id AND d.status = N'Active' AND d.dependency_type_id IS NOT NULL) AS TotalDependencyCategories,
       (SELECT COUNT(*) FROM grac_practice.practice_dependency_resolution r
         WHERE r.practice_instance_id = pi.practice_instance_id AND r.is_active = 1) AS ResolvedDependenciesCount
  FROM grac_practice.custom_gap cg
  JOIN grac_practice.gap_lifecycle_state_master s ON s.lifecycle_state_id = cg.lifecycle_state_id
  LEFT JOIN grac_practice.practice_instance pi
         ON pi.practice_instance_id = cg.source_reference_id
        AND cg.source_reference_type = N'PracticeInstance'
 WHERE s.state_code = N'Delegated'
   AND cg.gap_source_module_code = N'Implementation'
 ORDER BY cg.custom_gap_id DESC;

PRINT '';
PRINT '367 complete. Gap Center now shows every unresolved obligation (Not Implemented,';
PRINT 'Partially Implemented, Not Set) under a gap once created, and blocks Gap Analysis';
PRINT 'until all of them are resolved AND the related Practice is Operationalized. No';
PRINT 'C#/JS rebuild is required for the database side alone -- the API/UI changes';
PRINT '(GapHeader.IsPracticeOperationalized, gap-detail.js/cshtml blocked-banner) ship';
PRINT 'alongside this migration.';
GO

SET NOEXEC OFF;
GO
