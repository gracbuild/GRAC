-- =====================================================================
-- 339 Bulk reconcile of schedule rules (backfill)
--
-- WHY
-- ---
-- 338 syncs one instance's schedule streams and runs automatically after
-- each obligation save. Instances whose obligations were adopted BEFORE
-- that hook existed have schedulable obligations but no rule yet. This is
-- the one-off (and repeatable) backfill that brings them in: it walks
-- every instance that has a schedulable obligation and runs the same
-- per-instance sync, so there is ONE definition of "what the streams
-- should be" (sp_pm_sync_instance_schedule_rules) and this only chooses
-- which instances to run it for.
--
-- It replaces the old manual "Generate Schedules" flow, which created
-- instance-wide rules by hand -- the wrong shape now that cadence is
-- per obligation.
--
-- SCOPE
-- -----
-- @organization_id NULL  -> every organization.
-- @organization_id set   -> just that org.
-- No anchors are passed, so each new stream starts today and any stream
-- that already has an anchor keeps it (see 338).
--
-- SAFE TO RE-RUN: it is just the idempotent per-instance sync applied in
-- a loop; a second run over unchanged data writes nothing.
-- DEPENDS ON: 337 (schedulable view), 338 (per-instance sync).
-- Rollback: database/339_schedule_rule_reconcile_proc_rollback.sql
-- ASCII-only on purpose.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET NOEXEC OFF;
GO

DECLARE @prereqs_ok BIT = 1;

IF OBJECT_ID('grac_practice.sp_pm_sync_instance_schedule_rules','P') IS NULL
BEGIN PRINT 'ABORT (339): sp_pm_sync_instance_schedule_rules missing. Run 338 first.'; SET @prereqs_ok = 0; END

IF @prereqs_ok = 1 AND OBJECT_ID('grac_practice.vw_pm_instance_schedulable_obligations','V') IS NULL
BEGIN PRINT 'ABORT (339): vw_pm_instance_schedulable_obligations missing. Run 337 first.'; SET @prereqs_ok = 0; END

IF @prereqs_ok = 0
BEGIN
    RAISERROR('339_schedule_rule_reconcile_proc: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

CREATE OR ALTER PROCEDURE grac_practice.sp_pm_reconcile_schedule_rules
    @organization_id BIGINT        = NULL,
    @actor           NVARCHAR(100)  = N'system'
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @id BIGINT;

    -- Every instance that currently has at least one schedulable
    -- (Execution / Assurance, periodic) obligation. Instances with none
    -- are skipped -- the per-instance sync would only ever retire rules
    -- for them, and a plain backfill has nothing to retire.
    DECLARE inst CURSOR LOCAL FAST_FORWARD FOR
        SELECT DISTINCT s.PracticeInstanceId
        FROM   grac_practice.vw_pm_instance_schedulable_obligations s
        JOIN   grac_practice.practice_instance pi
               ON pi.practice_instance_id = s.PracticeInstanceId
        WHERE (@organization_id IS NULL OR pi.organization_id = @organization_id);

    OPEN inst;
    FETCH NEXT FROM inst INTO @id;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        EXEC grac_practice.sp_pm_sync_instance_schedule_rules
             @practice_instance_id = @id,
             @actor                = @actor,
             @anchors_json         = NULL;
        FETCH NEXT FROM inst INTO @id;
    END
    CLOSE inst;
    DEALLOCATE inst;

    -- Report: active per-obligation streams after the reconcile.
    SELECT COUNT(*) AS ActiveObligationStreams
    FROM   grac_practice.assurance_schedule_rule r
    JOIN   grac_practice.practice_instance pi
           ON pi.practice_instance_id = r.practice_instance_id
    WHERE  r.status = N'Active' AND r.is_active = 1
      AND  r.practice_instance_obligation_id IS NOT NULL
      AND (@organization_id IS NULL OR pi.organization_id = @organization_id);
END
GO

PRINT '339: sp_pm_reconcile_schedule_rules created.';
GO

-- =====================================================================
-- Verification
-- =====================================================================
PRINT '=== 339 verification ===';
SELECT 'reconcile proc created' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.sp_pm_reconcile_schedule_rules','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;

PRINT '';
PRINT 'To backfill every org now:  EXEC grac_practice.sp_pm_reconcile_schedule_rules;';
PRINT 'For one org:                 EXEC grac_practice.sp_pm_reconcile_schedule_rules @organization_id = <id>;';
GO
SET NOEXEC OFF;
GO
