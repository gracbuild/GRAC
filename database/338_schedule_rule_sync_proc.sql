-- =====================================================================
-- 338 Sync schedule rules from an instance's schedulable obligations
--
-- WHY
-- ---
-- 337 says WHICH obligations on an instance are schedulable and at what
-- cadence. This step turns that into rows: one active
-- assurance_schedule_rule per schedulable obligation, created and kept in
-- step automatically -- so the manual "Generate Schedules" click is no
-- longer the only way a schedule comes into being.
--
-- It is deliberately a SEPARATE proc, not a rewrite of
-- sp_resolve_obligation_adopt (226). Adoption is a large, delicate save;
-- the sync runs after it (the API calls this proc once adoption commits),
-- and it is safe to run on its own at any time -- which also makes it the
-- reconcile/backfill tool for instances adopted before this change.
--
-- ANCHOR (first occurrence)
-- -------------------------
-- The cadence comes from the obligation; the FIRST occurrence date does
-- not, so it is captured per obligation on practice_instance_obligation
-- (new column first_occurrence_date, set from the Operationalize screen).
-- When the caller passes @anchors_json the proc stores those dates first,
-- then schedules from them. A stream with no stated first occurrence
-- anchors to today. An existing rule's anchor is never silently moved:
-- it changes only when a first_occurrence_date is actually on record.
--
-- WHAT IT DOES
-- ------------
--   1. (optional) store per-obligation first_occurrence_date from JSON.
--   2. upsert one active rule per row of
--      vw_pm_instance_schedulable_obligations for the instance.
--   3. retire active rules whose obligation is no longer schedulable
--      (un-adopted, type changed, cadence gone non-periodic). Legacy rows
--      with no obligation id (pre-337 instance-wide rules) are left alone.
--
-- SAFE TO RE-RUN: idempotent -- MERGE upserts, the retire step is a no-op
-- once nothing dangles, and anchors only fill or change when supplied.
-- DEPENDS ON: 336 (per-obligation rule columns), 337 (schedulable view),
--             226 (practice_instance_obligation).
-- Rollback: database/338_schedule_rule_sync_proc_rollback.sql
-- ASCII-only on purpose.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET NOEXEC OFF;
GO

DECLARE @prereqs_ok BIT = 1;

IF OBJECT_ID('grac_practice.assurance_schedule_rule','U') IS NULL
   OR COL_LENGTH('grac_practice.assurance_schedule_rule','practice_instance_obligation_id') IS NULL
BEGIN PRINT 'ABORT (338): per-obligation schedule_rule columns missing. Run 336 first.'; SET @prereqs_ok = 0; END

IF @prereqs_ok = 1 AND OBJECT_ID('grac_practice.vw_pm_instance_schedulable_obligations','V') IS NULL
BEGIN PRINT 'ABORT (338): vw_pm_instance_schedulable_obligations missing. Run 337 first.'; SET @prereqs_ok = 0; END

IF @prereqs_ok = 1 AND OBJECT_ID('grac_practice.practice_instance_obligation','U') IS NULL
BEGIN PRINT 'ABORT (338): practice_instance_obligation missing. Run 140 first.'; SET @prereqs_ok = 0; END

IF @prereqs_ok = 0
BEGIN
    RAISERROR('338_schedule_rule_sync_proc: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

-- ---------------------------------------------------------------------
-- 1. Anchor column on the obligation adoption row.
-- ---------------------------------------------------------------------
IF COL_LENGTH('grac_practice.practice_instance_obligation','first_occurrence_date') IS NULL
BEGIN
    ALTER TABLE grac_practice.practice_instance_obligation
        ADD first_occurrence_date DATE NULL;
    PRINT '338: added practice_instance_obligation.first_occurrence_date';
END
ELSE PRINT '338: first_occurrence_date already present -- skipped';
GO

-- ---------------------------------------------------------------------
-- 2. The sync proc.
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE grac_practice.sp_pm_sync_instance_schedule_rules
    @practice_instance_id BIGINT,
    @actor                NVARCHAR(100)  = N'system',
    @anchors_json         NVARCHAR(MAX)  = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @practice_instance_id IS NULL
        THROW 52720, 'sp_pm_sync_instance_schedule_rules: practice_instance_id is required.', 1;

    DECLARE @org BIGINT =
        (SELECT organization_id FROM grac_practice.practice_instance
          WHERE practice_instance_id = @practice_instance_id);
    IF @org IS NULL
        THROW 52721, 'sp_pm_sync_instance_schedule_rules: instance not found.', 1;

    -- 1. Store per-obligation first-occurrence anchors, if supplied. A row
    --    may name the obligation by its adoption id or its obligation id;
    --    only a non-null date is written.
    IF @anchors_json IS NOT NULL AND ISJSON(@anchors_json) = 1
    BEGIN
        UPDATE pio
           SET first_occurrence_date = a.FirstOccurrenceDate,
               updated_by = @actor,
               updated_dt = SYSUTCDATETIME()
        FROM   grac_practice.practice_instance_obligation pio
        JOIN   OPENJSON(@anchors_json) WITH (
                   PracticeInstanceObligationId BIGINT '$.practiceInstanceObligationId',
                   ObligationId                 BIGINT '$.obligationId',
                   FirstOccurrenceDate          DATE   '$.firstOccurrenceDate'
               ) a
               ON  a.FirstOccurrenceDate IS NOT NULL
              AND (a.PracticeInstanceObligationId = pio.practice_instance_obligation_id
                   OR a.ObligationId = pio.obligation_id)
        WHERE  pio.practice_instance_id = @practice_instance_id;
    END

    BEGIN TRAN;

    -- 2. Upsert one ACTIVE rule per schedulable obligation. HOLDLOCK so a
    --    concurrent adoption cannot slip a second active row past the
    --    filtered UNIQUE (uq_pm_schedule_rule_obligation_active, 336).
    MERGE grac_practice.assurance_schedule_rule WITH (HOLDLOCK) AS tgt
    USING (
        SELECT s.PracticeInstanceObligationId,
               s.PracticeInstanceId,
               s.ScheduleKind,
               s.FrequencyId,
               pio.first_occurrence_date AS FirstOcc
        FROM   grac_practice.vw_pm_instance_schedulable_obligations s
        JOIN   grac_practice.practice_instance_obligation pio
               ON pio.practice_instance_obligation_id = s.PracticeInstanceObligationId
        WHERE  s.PracticeInstanceId = @practice_instance_id
    ) AS src
       ON  tgt.practice_instance_obligation_id = src.PracticeInstanceObligationId
      AND  tgt.status    = N'Active'
      AND  tgt.is_active = 1
    WHEN MATCHED THEN UPDATE SET
           frequency_id  = src.FrequencyId,
           schedule_kind = src.ScheduleKind,
           -- Only a stated first occurrence moves an existing anchor.
           anchor_date   = COALESCE(src.FirstOcc, tgt.anchor_date),
           updated_by    = @actor,
           updated_dt    = SYSUTCDATETIME()
    WHEN NOT MATCHED THEN INSERT
           (organization_id, practice_instance_id, practice_instance_obligation_id,
            frequency_id, anchor_date, schedule_kind, is_active, status, entered_by)
         VALUES
           (@org, src.PracticeInstanceId, src.PracticeInstanceObligationId,
            src.FrequencyId, COALESCE(src.FirstOcc, CAST(SYSUTCDATETIME() AS DATE)),
            src.ScheduleKind, 1, N'Active', @actor);

    -- 3. Retire active rules whose obligation is no longer schedulable.
    --    Legacy instance-wide rows (no obligation id) are outside this.
    UPDATE r
       SET status     = N'Retired',
           is_active  = 0,
           updated_by = @actor,
           updated_dt = SYSUTCDATETIME()
    FROM   grac_practice.assurance_schedule_rule r
    WHERE  r.practice_instance_id = @practice_instance_id
      AND  r.status    = N'Active'
      AND  r.is_active = 1
      AND  r.practice_instance_obligation_id IS NOT NULL
      AND  NOT EXISTS (SELECT 1 FROM grac_practice.vw_pm_instance_schedulable_obligations s
                        WHERE s.PracticeInstanceObligationId = r.practice_instance_obligation_id);

    COMMIT TRAN;
END
GO

PRINT '338: sp_pm_sync_instance_schedule_rules created.';
GO

-- =====================================================================
-- Verification
-- =====================================================================
PRINT '=== 338 verification ===';
SELECT 'anchor column exists' AS Check_,
       CASE WHEN COL_LENGTH('grac_practice.practice_instance_obligation','first_occurrence_date') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT 'sync proc created',
       CASE WHEN OBJECT_ID('grac_practice.sp_pm_sync_instance_schedule_rules','P') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END;

PRINT '';
PRINT '338 complete. The API calls this after adoption; it is also safe to';
PRINT 'run by hand per instance as a reconcile/backfill.';
GO
SET NOEXEC OFF;
GO
