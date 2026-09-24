-- =====================================================================
-- 324 Gap Analysis: status actually reaches "Analysed", and an already-
--     analysed gap can no longer be re-analysed
--
-- REPORT
-- ------
-- "Currently, after completing the analysis, the item is still remaining
--  in the previous status. It is not changing to Analysed." Also: once a
--  gap is Analysed, the user should see View only -- Analyse should be
--  hidden/disabled, both in the UI and at the API, so an already-
--  analysed gap cannot be re-analysed by calling the endpoint directly.
--
-- ROOT CAUSE -- part 1 (status not updating)
-- --------------------------------------------------------------------
-- "Analysed" is not a separate lifecycle state -- it is the *display*
-- name (175/319) of state_code = 'Delegated'. A gap reaches it through
-- the "Auto-transition to Delegated" block at the end of
-- sp_custom_gap_analysis_save (added by 174, carried unchanged through
-- 252 and 323). That block looks up the gap's CURRENT state itself,
-- before deciding whether to fire the Delegate transition:
--
--     SELECT @current_state_code = s.state_code
--       FROM grac_practice.custom_gap g
--       JOIN grac_practice.gap_lifecycle_state_master s
--            ON s.lifecycle_state_id = g.lifecycle_state_id
--      WHERE g.custom_gap_id = @custom_gap_id;
--     IF @current_state_code IN (N'New', N'Validation', N'Analysis') ...
--
-- custom_gap.lifecycle_state_id is NULLable (156) and is NEVER populated
-- by sp_custom_gap_open (250, the proc behind the Gap Centre "Add Gap"
-- dialog every Custom gap is created through) or by sp_custom_gap_save's
-- create branch (116b). For every such gap the INNER JOIN above matches
-- zero rows, @current_state_code stays NULL, "NULL IN (...)" is neither
-- true nor false in T-SQL (UNKNOWN), and the IF is skipped -- silently,
-- with no error and not even a PRINT, because the skip happens before
-- the block's own TRY even starts. The gap's lifecycle_state_id is never
-- set, sp_gap_centre_list (318) falls back to the raw custom_gap.status
-- ('Open'), and the Gap Centre list -- and the gap-detail stepper --
-- keep showing the pre-analysis status forever. This matches the report
-- exactly, and matches gaps materialized from a Practice Instance NOT
-- showing the bug: sp_custom_gap_materialize_for_instance (160) DOES
-- stamp lifecycle_state_id = the 'New' state's id at creation, so the
-- INNER JOIN there always finds a row.
--
-- The engine this block calls, sp_custom_gap_lifecycle_transition (157),
-- has ALWAYS had the correct defensive handling for exactly this case:
-- "IF @current_state_id IS NULL ... treat its current state as 'New'".
-- The auto-Delegate block's own pre-check never had the same fallback --
-- this migration gives it one, and additionally captures the outcome
-- (success/error) into the second result set 323 introduced, so a
-- transition failure from any OTHER cause is visible too instead of only
-- PRINTed.
--
-- FIX -- part 1
-- -------------
--   1. sp_custom_gap_analysis_save's auto-Delegate block: LEFT JOIN
--      instead of INNER JOIN, NULL treated as 'New' (same rule 157 already
--      uses), and the transition's own success/error captured into the
--      result set (LifecycleTransitioned/LifecycleError) alongside the
--      fresh LifecycleStateCode/LifecycleStateName -- so the API (and,
--      from there, the UI) can see the true post-save state directly
--      from the save call, not only by inference.
--   2. Belt-and-suspenders, matching how 323 re-asserted 253's task-open
--      fix: sp_custom_gap_open and sp_custom_gap_save's create branch now
--      also stamp lifecycle_state_id = 'New' at creation, exactly as
--      sp_custom_gap_materialize_for_instance (160) already does -- so a
--      freshly created gap is never NULL in the first place, on any
--      creation path, regardless of the fallback in (1).
--
-- ROOT CAUSE + FIX -- part 2 (re-analysis of an already-Analysed gap)
-- --------------------------------------------------------------------
-- 173 added a terminal-invalid guard to sp_custom_gap_analysis_save
-- (is_terminal = 1 AND is_valid_terminal = 0 -- Invalid/Duplicate). It
-- deliberately does not cover Delegated/"Analysed", which is terminal
-- but is_valid_terminal = 1 -- so there has never been a guard against
-- re-analysing an already-Analysed gap. This migration adds the missing
-- counterpart: a save is rejected with THROW 55143 when the gap is
-- currently in a terminal-VALID state (today, only Delegated/"Analysed").
-- A gap whose lifecycle_state_id is NULL is not terminal (it is "New" per
-- the same fallback as part 1), so a first analysis is never blocked.
-- This enforces "cannot be analysed again by directly calling the API",
-- not only in the UI -- the UI change (gaps.cshtml row menu, gap-detail
-- form lock) is shipped alongside this migration, reusing the existing
-- terminal-invalid lock mechanism gap-detail.js already has from 173.
--
-- SCOPE
--   1. sp_custom_gap_open                 -- re-issued from 250, stamps
--                                             lifecycle_state_id = New
--   2. sp_custom_gap_save                  -- re-issued from 116b, same
--                                             stamp on the create branch
--                                             only (update branch unchanged)
--   3. sp_custom_gap_analysis_save         -- re-issued from 323:
--                                             + 55143 re-analysis guard
--                                             + NULL-safe auto-Delegate
--                                             + LifecycleTransitioned/
--                                               LifecycleError/
--                                               LifecycleStateCode/
--                                               LifecycleStateName added
--                                               to the second result set
--   4. sp_gap_centre_list                  -- re-issued from 318, adds
--                                             LifecycleStateCode (raw
--                                             state_code, NULL on the
--                                             practice_gap arm) so the
--                                             UI can gate View/Analyse on
--                                             the code, not the display
--                                             text ("Analysed" is only a
--                                             label -- 175/319 already
--                                             changed it once).
--
-- No schema change. No data migration -- existing rows with a NULL
-- lifecycle_state_id are handled by the fallback in (3) the next time
-- they are analysed or re-saved; nothing here back-fills historical rows
-- server-side (see the spot-check in the verification block below for
-- how many currently qualify, if a DBA wants to run one manually).
--
-- Rollback: 324_gap_analysis_status_and_reanalysis_guard_rollback.sql
-- (restores all four procs to their exact pre-324 bodies: sp_custom_gap_
-- open to 250's, sp_custom_gap_save to 116b's, sp_custom_gap_analysis_
-- save to 323's, sp_gap_centre_list to 318's).
--
-- SAFE TO RE-RUN. Requires 156, 157, 160, 173, 174, 250, 255, 318, 323.
-- ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

DECLARE @ok BIT = 1;
IF SCHEMA_ID('grac_practice') IS NULL
BEGIN PRINT 'ABORT (324): schema grac_practice missing.'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.custom_gap','U') IS NULL
BEGIN PRINT 'ABORT (324): custom_gap missing (run 054 first).'; SET @ok = 0; END
IF COL_LENGTH('grac_practice.custom_gap','lifecycle_state_id') IS NULL
BEGIN PRINT 'ABORT (324): custom_gap.lifecycle_state_id missing (run 156 first).'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.gap_lifecycle_state_master','U') IS NULL
BEGIN PRINT 'ABORT (324): gap_lifecycle_state_master missing (run 156 first).'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.sp_custom_gap_lifecycle_transition','P') IS NULL
BEGIN PRINT 'ABORT (324): sp_custom_gap_lifecycle_transition missing (run 157 first).'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.sp_custom_gap_open','P') IS NULL
BEGIN PRINT 'ABORT (324): sp_custom_gap_open missing (run 055/250 first).'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.sp_custom_gap_save','P') IS NULL
BEGIN PRINT 'ABORT (324): sp_custom_gap_save missing (run 116b first).'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.sp_custom_gap_analysis_save','P') IS NULL
BEGIN PRINT 'ABORT (324): sp_custom_gap_analysis_save missing (run 323 first).'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.sp_gap_centre_list','P') IS NULL
BEGIN PRINT 'ABORT (324): sp_gap_centre_list missing (run 255/318 first).'; SET @ok = 0; END
IF NOT EXISTS (SELECT 1 FROM grac_practice.gap_lifecycle_state_master WHERE state_code = N'New')
BEGIN PRINT 'ABORT (324): lifecycle state New missing (run 158 seed first).'; SET @ok = 0; END
IF @ok = 0
BEGIN
    RAISERROR('324_gap_analysis_status_and_reanalysis_guard: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. sp_custom_gap_open -- re-issued from 250, now stamps New at birth
--
-- Byte-for-byte 250's body except: the New state's id is looked up once
-- (same pattern as 160's materialize proc) and added to the INSERT
-- column list. Everything else -- parameters, validation, defaults -- is
-- unchanged.
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

    -- Migration 324: stamp the gap into the v1 lifecycle at birth, the
    -- same way sp_custom_gap_materialize_for_instance (160) always has.
    -- Missing before this migration -- see the header note above for why
    -- that made a Custom gap's status silently never reach Analysed.
    DECLARE @new_state_id INT =
        (SELECT lifecycle_state_id FROM grac_practice.gap_lifecycle_state_master WHERE state_code = N'New');

    INSERT INTO grac_practice.custom_gap
        (organization_id, gap_type_code, title, description, priority,
         owner_employee_id, due_date, status, remarks,
         severity_code, severity_name,
         detection_method_code, detection_method_name,
         lifecycle_state_id,
         entered_by, entered_dt)
    VALUES
        (@organization_id, ISNULL(@gap_type_code, N'Custom'),
         @title, @description, @priority,
         @owner_employee_id, @due_date, @status, @remarks,
         @severity_code, @severity_name,
         NULLIF(LTRIM(RTRIM(@detection_method_code)), N''),
         NULLIF(LTRIM(RTRIM(@detection_method_name)), N''),
         @new_state_id,
         COALESCE(CAST(@actor_employee_id AS NVARCHAR(100)), 'api'),
         SYSUTCDATETIME());

    SET @custom_gap_id = SCOPE_IDENTITY();
END
GO
PRINT '324: sp_custom_gap_open now stamps lifecycle_state_id = New at creation.';
GO

-- =====================================================================
-- 2. sp_custom_gap_save -- re-issued from 116b, create branch only
--
-- Byte-for-byte 116b's body except the INSERT's create branch (@custom_
-- gap_id IS NULL) now also stamps lifecycle_state_id. The UPDATE
-- (edit) branch is untouched -- an existing gap's lifecycle state is
-- never a field this proc's edit path is meant to move.
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

    -- ==========================================================
    -- Owner hybrid resolver
    -- ==========================================================
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

    -- ==========================================================
    -- Reviewer hybrid resolver (same shape)
    -- ==========================================================
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
        -- Migration 324: same New-state stamp as sp_custom_gap_open,
        -- looked up once before the INSERT. See the migration header.
        DECLARE @new_state_id INT =
            (SELECT lifecycle_state_id FROM grac_practice.gap_lifecycle_state_master WHERE state_code = N'New');

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
            lifecycle_state_id,
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
            @new_state_id,
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
PRINT '324: sp_custom_gap_save now stamps lifecycle_state_id = New on create.';
GO

-- =====================================================================
-- 3. sp_custom_gap_analysis_save -- re-analysis guard + NULL-safe delegate
--
-- 323's body with:
--   * NEW guard (55143), right after the existing terminal-invalid guard
--     (173/55142): rejects the save outright when the gap is currently
--     in a terminal-VALID state (today, only Delegated/"Analysed").
--     lifecycle_state_id = NULL is treated as 'New' (not terminal), so a
--     first-time analysis is never blocked.
--   * The "Auto-transition to Delegated" block: LEFT JOIN instead of
--     INNER JOIN, NULL current-state treated as 'New' (matching
--     sp_custom_gap_lifecycle_transition's own long-standing fallback),
--     and the transition's outcome captured instead of only PRINTed.
--   * Second result set gains LifecycleTransitioned / LifecycleError /
--     LifecycleStateCode / LifecycleStateName alongside the existing
--     Task/Exception/Risk columns.
-- Everything else (parameters, MERGE, the three auto-triggers,
-- preventive_action) is unchanged from 323.
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
    -- Migration 324 fix: LEFT JOIN + NULL treated as 'New' (see header --
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

    -- Migration 324: LifecycleTransitioned/LifecycleError/
    -- LifecycleStateCode/LifecycleStateName added alongside 323's
    -- Task/Exception/Risk outcome columns.
    SELECT
        @task_created      AS TaskCreated,      @task_error      AS TaskError,
        @exception_created AS ExceptionCreated, @exception_error AS ExceptionError,
        @risk_created      AS RiskCreated,      @risk_error      AS RiskError,
        @lifecycle_transitioned AS LifecycleTransitioned, @lifecycle_error AS LifecycleError,
        @final_state_code       AS LifecycleStateCode,    @final_state_name AS LifecycleStateName;
END
GO
PRINT '324: sp_custom_gap_analysis_save -- re-analysis guard added, auto-delegate NULL-safe, outcome surfaced.';
GO

-- =====================================================================
-- 4. sp_gap_centre_list -- adds LifecycleStateCode (raw state_code)
--
-- Byte-for-byte 318's body plus one new projected column on the
-- custom_gap arm: LifecycleStateCode (s.state_code), NULL on the
-- practice_gap arm exactly like RawStatusCode already is. StatusText
-- (the display name) is unchanged -- this is purely additive, so the
-- grid can gate "View" vs "Analysis" on the stable code instead of the
-- display text, which 175/319 already show is not stable wording.
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
        -- Migration 324: the lifecycle state_code itself (NOT the display
        -- name in StatusText), NULL on the practice_gap arm. Lets the UI
        -- gate View/Analyse on a stable code ('Delegated') rather than a
        -- label 175/319 already show can be re-worded.
        LifecycleStateCode NVARCHAR(60)  NULL,
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

    -- ---- Arm 1: custom_gap, every source module ---------------------
    INSERT INTO @results
        (RowKey, SourceModuleCode, CustomGapId, PracticeGapId, PracticeInstanceId,
         IsMaterialized, Title, Context, StatusText, RawStatusCode, LifecycleStateCode,
         SeverityText, OwnerText,
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
        s.state_code,
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

    -- ---- Arm 2: practice_gap not yet materialized -------------------
    IF (@source_module_code IS NULL OR @source_module_code = N'Implementation')
       AND @observation_id IS NULL
    INSERT INTO @results
        (RowKey, SourceModuleCode, CustomGapId, PracticeGapId, PracticeInstanceId,
         IsMaterialized, Title, Context, StatusText, RawStatusCode, LifecycleStateCode,
         SeverityText, OwnerText,
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
        NULL,                       -- 324: no lifecycle state yet either
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

    -- Result set 1 -- paging metadata, same contract as every other list.
    SELECT COUNT_BIG(*) AS TotalCount,
           @page        AS PageNumber,
           @page_size   AS PageSize
    FROM   @results;

    -- Result set 2 -- the page.
    SELECT RowKey, SourceModuleCode, CustomGapId, PracticeGapId,
           PracticeInstanceId, IsMaterialized, Title, Context,
           StatusText, RawStatusCode, LifecycleStateCode,
           SeverityText, OwnerText, DueDate, OpenedDt,
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
PRINT '324: sp_gap_centre_list now also projects LifecycleStateCode.';
GO

-- =====================================================================
-- Verification
-- =====================================================================
PRINT '=== 324 verification ===';

DECLARE @open NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_custom_gap_open','P'));
DECLARE @save NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_custom_gap_save','P'));
DECLARE @ansv NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_custom_gap_analysis_save','P'));
DECLARE @list NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_gap_centre_list','P'));

SELECT '324-a sp_custom_gap_open stamps lifecycle_state_id' AS Check_,
       CASE WHEN @open LIKE '%lifecycle_state_id%' AND @open LIKE '%@new_state_id%' THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '324-b sp_custom_gap_save create branch stamps lifecycle_state_id',
       CASE WHEN @save LIKE '%lifecycle_state_id%' AND @save LIKE '%@new_state_id%' THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '324-c analysis_save has the new re-analysis guard (55143)',
       CASE WHEN @ansv LIKE '%55143%' AND @ansv LIKE '%is_valid_terminal = 1%' THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '324-d analysis_save still guards terminal-invalid (173/55142)',
       CASE WHEN @ansv LIKE '%55142%' THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '324-e auto-delegate lookup is now a LEFT JOIN with NULL treated as New',
       CASE WHEN @ansv LIKE '%LEFT JOIN grac_practice.gap_lifecycle_state_master s ON s.lifecycle_state_id = g.lifecycle_state_id%'
             AND @ansv LIKE '%IF @current_state_code IS NULL SET @current_state_code = N''New''%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '324-f analysis_save second result set carries LifecycleTransitioned/LifecycleStateCode',
       CASE WHEN @ansv LIKE '%AS LifecycleTransitioned%' AND @ansv LIKE '%AS LifecycleStateCode%' THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '324-g analysis_save still returns CustomGapId result set',
       CASE WHEN @ansv LIKE '%AS CustomGapId%' THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '324-h analysis_save still declares all 21 parameters (unchanged from 323)',
       CASE WHEN (SELECT COUNT(*) FROM sys.parameters
                   WHERE object_id = OBJECT_ID('grac_practice.sp_custom_gap_analysis_save','P')) = 21
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '324-i sp_gap_centre_list now projects LifecycleStateCode',
       CASE WHEN @list LIKE '%LifecycleStateCode%' THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '324-j sp_gap_centre_list still projects RawStatusCode (318 kept)',
       CASE WHEN @list LIKE '%RawStatusCode%' THEN 'PASS' ELSE 'FAIL' END;

PRINT '';
PRINT '--- Spot check: gaps whose lifecycle_state_id is currently NULL (would have';
PRINT '    silently never reached Analysed before this migration) ---';
SELECT COUNT(*) AS GapsWithNullLifecycleState
  FROM grac_practice.custom_gap
 WHERE lifecycle_state_id IS NULL;

PRINT '';
PRINT '--- Spot check: current per-lifecycle-state distribution ---';
SELECT COALESCE(s.state_name, N'(NULL lifecycle_state_id)') AS StatusShownInGapCentre,
       COUNT(*)                                             AS GapCount
  FROM grac_practice.custom_gap cg
  LEFT JOIN grac_practice.gap_lifecycle_state_master s ON s.lifecycle_state_id = cg.lifecycle_state_id
 GROUP BY COALESCE(s.state_name, N'(NULL lifecycle_state_id)')
 ORDER BY GapCount DESC;

PRINT '';
PRINT '324 complete. New Custom gaps are stamped New at birth; analysis save now';
PRINT 'reliably auto-delegates to Analysed and rejects a second analysis attempt.';
GO

SET NOEXEC OFF;
GO
