-- =====================================================================
-- 355 Retire / Restore now require a reason
--
-- WHY
-- ---
-- Both surfaces that can take a practice instance out of service, or
-- bring one back, ask for nothing but a click today:
--
--   * resolve-workspace.cshtml  -- the "Retire instance" / "Restore
--     instance" buttons on the instance's own Operationalize page.
--   * resolve.cshtml            -- the 3-dot row menu on the
--     Operationalize LIST page.
--
-- Both call the exact same two endpoints (287's own comment: "so the
-- row menu and the workspace cannot diverge in what they enforce"), so
-- both already get this fix from one change to the two procedures
-- underneath -- POST /practice/api/workflow/resolve/retire and
-- .../restore, backed by sp_resolve_instance_retire (222) and
-- sp_resolve_instance_restore (287).
--
-- Today each is a plain window.gracUi.confirm() with no text entry, so
-- an instance can be archived, or brought back into work queues and
-- assurance scheduling, with nothing recorded about why. Once retired
-- or restored there was also nowhere to ever ask: neither procedure
-- wrote a row anywhere describing the act, only the instance's own
-- status and updated_by/updated_dt -- which the next status change
-- overwrites.
--
-- THE FIX
--   1. New table practice_instance_status_history, one row per retire
--      or restore, same shape as the risk_register_history /
--      exception_request_history precedent already used elsewhere in
--      this schema (205, 161): action code, from/to status, remark,
--      actor, timestamp. Additive only -- nothing reads this table yet,
--      so nothing existing can regress from its arrival.
--
--   2. sp_resolve_instance_retire re-issued from 222's exact body plus:
--        - a new required @remark NVARCHAR(1000) parameter, refused
--          (THROW) when NULL or blank -- the UI is the enforcement
--          point for "ask before the click", but the procedure is the
--          one point every caller (workspace button, row menu, and any
--          future caller) must pass through, so it is also the one
--          place this rule cannot be bypassed.
--        - one INSERT into the new history table, after the existing
--          UPDATE, logging what changed and why.
--      Every guard 222 wrote (ownership, "already retired") is
--      reproduced unchanged and runs BEFORE the new remark check, so a
--      caller who was never going to be allowed to retire this instance
--      still gets that refusal first, not a confusing "remark required"
--      for an action they cannot perform anyway.
--
--   3. sp_resolve_instance_restore re-issued from 287's exact body the
--      same way -- required @remark, same ordering (ownership, state,
--      parent-practice-active, THEN remark), one history row.
--
-- WHAT THIS DOES NOT DO
--   * Does not touch sp_resolve_instance_list, sp_resolve_instance_
--     detail, or anything else 222/287 also defined -- only the two
--     retire/restore procedures are re-issued here.
--   * Does not change what retire/restore touch on practice_instance
--     itself -- still exactly status, record_status_id, updated_by,
--     updated_dt. The remark lives in the new history table, not as a
--     new column on practice_instance.
--   * Does not add a UI to browse this history yet. That is a fair
--     follow-up (an "Instance history" panel on the workspace page) but
--     is not part of what was asked for here, and nothing about the
--     data model below would need to change to add it later.
--   * Does not touch the deactivated Practice Instances grid screen's
--     retire path (dbo.pm_manage_practice_repository's generic RETIRE
--     block) -- that screen's menu row was hidden in 288 and is not
--     either of the two surfaces this was asked about.
--
-- API / UI (companion changes, not in this file)
--   Api/Models/ResolveWorkspaceModels.cs        -- + Remark on both
--                                                  request records
--   Api/Services/ResolveWorkspaceService.cs     -- binds @remark
--   Web/wwwroot/js/grac-dialog.js               -- new promptRequired()
--   Web/Views/Practice/Partials/resolve-workspace.cshtml
--   Web/Views/Practice/Partials/resolve.cshtml
--   This is a stored-procedure contract change (a new required
--   parameter with no default), so the API tier must be rebuilt after
--   this migration runs -- see the chat explanation for what that
--   involves.
--
-- ERROR CODE RANGE: 52815-52819 (52680-52683 already belong to 222's
--                   own retire; 52810-52814 to 287's restore; both left
--                   untouched below).
-- Re-runnable: yes (CREATE OR ALTER; table create is guarded).
-- Rollback: database/355_resolve_instance_retire_restore_reason_rollback.sql
-- DEPENDS ON: 222 (sp_resolve_instance_retire), 287 (sp_resolve_
--             instance_restore).
-- ASCII-only on purpose (sqlcmd codepage safety).
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.sp_resolve_instance_retire','P') IS NULL
   OR OBJECT_ID('grac_practice.sp_resolve_instance_restore','P') IS NULL
BEGIN
    PRINT 'ABORT (355): sp_resolve_instance_retire / _restore missing. Run 222 and 287 first.';
    RAISERROR('355_resolve_instance_retire_restore_reason: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 0. practice_instance_status_history -- new, additive
--
-- One row per retire/restore, so the reason typed on the UI has
-- somewhere to live. Same shape as risk_register_history (205) and
-- exception_request_history (161): this schema already has a settled
-- pattern for "an action, a status transition, a remark, an actor" and
-- there is no reason to invent a different one here.
-- =====================================================================
IF OBJECT_ID('grac_practice.practice_instance_status_history','U') IS NULL
BEGIN
    CREATE TABLE grac_practice.practice_instance_status_history(
        history_id            BIGINT IDENTITY(1,1) NOT NULL
            CONSTRAINT pk_pm_practice_instance_status_history PRIMARY KEY,
        practice_instance_id  BIGINT NOT NULL
            CONSTRAINT fk_pm_practice_instance_status_history_instance
                REFERENCES grac_practice.practice_instance(practice_instance_id),
        action_code           NVARCHAR(40) NOT NULL,   -- Retire / Restore
        from_status_code      NVARCHAR(30) NULL,
        to_status_code        NVARCHAR(30) NULL,
        remark                NVARCHAR(1000) NOT NULL,
        actor_employee_id     BIGINT NULL,
        actor_display_name    NVARCHAR(100) NULL,
        entered_by NVARCHAR(100) NOT NULL
            CONSTRAINT df_pm_practice_instance_status_history_entered_by DEFAULT N'system',
        entered_dt DATETIME2 NOT NULL
            CONSTRAINT df_pm_practice_instance_status_history_entered_dt DEFAULT SYSUTCDATETIME()
    );
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
                WHERE name = 'ix_pm_practice_instance_status_history_instance'
                  AND object_id = OBJECT_ID('grac_practice.practice_instance_status_history'))
    CREATE INDEX ix_pm_practice_instance_status_history_instance
        ON grac_practice.practice_instance_status_history(practice_instance_id, entered_dt DESC);
GO

-- =====================================================================
-- 1. sp_resolve_instance_retire -- re-issued from 222, + required @remark
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_resolve_instance_retire
    @practice_instance_id BIGINT,
    @caller_employee_id   BIGINT        = NULL,
    @is_admin             BIT           = 0,
    @actor                NVARCHAR(100) = N'system',
    -- NEW in 355. Required: the UI now asks for this before the click
    -- reaches the server, and the procedure is where that rule is
    -- actually enforced for every caller.
    @remark                NVARCHAR(1000) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @practice_instance_id IS NULL
        THROW 52680, 'sp_resolve_instance_retire: practice_instance_id is required.', 1;

    DECLARE @current_owner_id BIGINT, @current_status NVARCHAR(30);

    SELECT @current_owner_id = primary_owner_id,
           @current_status   = status
    FROM   grac_practice.practice_instance
    WHERE  practice_instance_id = @practice_instance_id;

    IF @current_status IS NULL
        THROW 52681, 'sp_resolve_instance_retire: instance not found.', 1;

    IF @is_admin = 0 AND ISNULL(@current_owner_id, -1) <> ISNULL(@caller_employee_id, -2)
        THROW 52682, 'sp_resolve_instance_retire: this practice instance belongs to another owner.', 1;

    IF @current_status <> N'Active'
        THROW 52683, 'sp_resolve_instance_retire: this practice instance is already retired.', 1;

    -- Checked last, after every guard above that would refuse the act
    -- outright, so a caller who cannot retire this instance at all sees
    -- that refusal first, not a confusing "reason required" for an
    -- action they were never going to be allowed to take.
    IF @remark IS NULL OR LEN(LTRIM(RTRIM(@remark))) = 0
        THROW 52815, 'sp_resolve_instance_retire: a reason for retiring this instance is required.', 1;

    DECLARE @inactive_record_status_id INT = (
        SELECT TOP 1 record_status_id
        FROM   grac_practice.record_status_master
        WHERE  status_code = N'Inactive' OR status_name = N'Inactive'
        ORDER  BY record_status_id
    );

    UPDATE grac_practice.practice_instance
       SET status           = N'Inactive',
           record_status_id = COALESCE(@inactive_record_status_id, record_status_id),
           updated_by       = @actor,
           updated_dt       = SYSUTCDATETIME()
     WHERE practice_instance_id = @practice_instance_id;

    INSERT INTO grac_practice.practice_instance_status_history(
        practice_instance_id, action_code, from_status_code, to_status_code,
        remark, actor_employee_id, actor_display_name, entered_by)
    VALUES (
        @practice_instance_id, N'Retire', N'Active', N'Inactive',
        LTRIM(RTRIM(@remark)), @caller_employee_id, @actor, @actor);

    SELECT CAST(1 AS BIT) AS Success,
           N'Practice instance retired.' AS Message,
           pi.status AS Status
    FROM   grac_practice.practice_instance pi
    WHERE  pi.practice_instance_id = @practice_instance_id;
END
GO
PRINT '355: sp_resolve_instance_retire now requires a reason and logs it.';
GO

-- =====================================================================
-- 2. sp_resolve_instance_restore -- re-issued from 287, + required @remark
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_resolve_instance_restore
    @practice_instance_id BIGINT,
    @caller_employee_id   BIGINT        = NULL,
    @is_admin             BIT           = 0,
    @actor                NVARCHAR(100) = N'system',
    -- NEW in 355. Same rule, same reason, as retire's.
    @remark                NVARCHAR(1000) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @practice_instance_id IS NULL
        THROW 52810, 'sp_resolve_instance_restore: practice_instance_id is required.', 1;

    DECLARE @current_owner_id BIGINT, @current_status NVARCHAR(30), @practice_id BIGINT;

    SELECT @current_owner_id = primary_owner_id,
           @current_status   = status,
           @practice_id      = practice_id
    FROM   grac_practice.practice_instance
    WHERE  practice_instance_id = @practice_instance_id;

    IF @current_status IS NULL
        THROW 52811, 'sp_resolve_instance_restore: instance not found.', 1;

    IF @is_admin = 0 AND ISNULL(@current_owner_id, -1) <> ISNULL(@caller_employee_id, -2)
        THROW 52812, 'sp_resolve_instance_restore: this practice instance belongs to another owner.', 1;

    IF @current_status = N'Active'
        THROW 52813, 'sp_resolve_instance_restore: this practice instance is already active.', 1;

    IF EXISTS (SELECT 1 FROM grac_practice.practice
                WHERE practice_id = @practice_id AND status <> N'Active')
        THROW 52814, 'sp_resolve_instance_restore: the parent practice is not active. Restore the practice first.', 1;

    -- Same ordering as retire: every guard that can refuse the act
    -- outright runs first, the reason requirement runs last.
    IF @remark IS NULL OR LEN(LTRIM(RTRIM(@remark))) = 0
        THROW 52816, 'sp_resolve_instance_restore: a reason for restoring this instance is required.', 1;

    DECLARE @active_record_status_id INT = (
        SELECT TOP 1 record_status_id
        FROM   grac_practice.record_status_master
        WHERE  status_code = N'Active' OR status_name = N'Active'
        ORDER  BY record_status_id
    );

    UPDATE grac_practice.practice_instance
       SET status           = N'Active',
           record_status_id = COALESCE(@active_record_status_id, record_status_id),
           updated_by       = @actor,
           updated_dt       = SYSUTCDATETIME()
     WHERE practice_instance_id = @practice_instance_id;

    INSERT INTO grac_practice.practice_instance_status_history(
        practice_instance_id, action_code, from_status_code, to_status_code,
        remark, actor_employee_id, actor_display_name, entered_by)
    VALUES (
        @practice_instance_id, N'Restore', N'Inactive', N'Active',
        LTRIM(RTRIM(@remark)), @caller_employee_id, @actor, @actor);

    SELECT CAST(1 AS BIT) AS Success,
           N'Practice instance restored.' AS Message,
           pi.status AS Status
    FROM   grac_practice.practice_instance pi
    WHERE  pi.practice_instance_id = @practice_instance_id;
END
GO
PRINT '355: sp_resolve_instance_restore now requires a reason and logs it.';
GO

-- =====================================================================
-- Verification
-- =====================================================================
PRINT '=== 355 verification ===';

DECLARE @rt NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_resolve_instance_retire','P'));
DECLARE @rs NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_resolve_instance_restore','P'));

SELECT '355-a practice_instance_status_history exists' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.practice_instance_status_history','U') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '355-b retire takes @remark',
       CASE WHEN EXISTS (SELECT 1 FROM sys.parameters
                          WHERE object_id = OBJECT_ID('grac_practice.sp_resolve_instance_retire')
                            AND name = '@remark')
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '355-c restore takes @remark',
       CASE WHEN EXISTS (SELECT 1 FROM sys.parameters
                          WHERE object_id = OBJECT_ID('grac_practice.sp_resolve_instance_restore')
                            AND name = '@remark')
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '355-d retire refuses a blank remark',
       CASE WHEN @rt LIKE '%52815%' AND @rt LIKE '%LEN(LTRIM(RTRIM(@remark))) = 0%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '355-e restore refuses a blank remark',
       CASE WHEN @rs LIKE '%52816%' AND @rs LIKE '%LEN(LTRIM(RTRIM(@remark))) = 0%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '355-f retire still enforces ownership before the remark check',
       CASE WHEN @rt LIKE '%52682%this practice instance belongs to another owner%52815%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '355-g restore still enforces parent-practice-active before the remark check',
       CASE WHEN @rs LIKE '%52814%the parent practice is not active%52816%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '355-h retire logs to the history table',
       CASE WHEN @rt LIKE '%INSERT INTO grac_practice.practice_instance_status_history%'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '355-i restore logs to the history table',
       CASE WHEN @rs LIKE '%INSERT INTO grac_practice.practice_instance_status_history%'
            THEN 'PASS' ELSE 'FAIL' END;

PRINT '';
PRINT '355 complete. Retire and Restore now both refuse a call with no';
PRINT 'reason (THROW 52815 / 52816), and every retire or restore -- from';
PRINT 'either the workspace buttons or the Operationalize list''s row menu,';
PRINT 'both of which call these same two procedures -- writes one row to';
PRINT 'practice_instance_status_history recording what changed and why.';
PRINT 'This is a new required stored-procedure parameter, so the API tier';
PRINT '(PracticeManagement.Api) must be rebuilt before existing callers can';
PRINT 'pass @remark -- see the accompanying C#/JS changes.';
GO

SET NOEXEC OFF;
GO
