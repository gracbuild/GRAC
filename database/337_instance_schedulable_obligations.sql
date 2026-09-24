-- =====================================================================
-- 337 Schedulable obligations per instance (Execution + Assurance)
--
-- WHY
-- ---
-- 237 answered "what is this instance's single assurance cadence?" by
-- collapsing every Assurance obligation to the shortest one and ignoring
-- Execution entirely. The calendar now wants the opposite: ONE stream
-- per schedulable obligation, each keeping its own cadence, and Execution
-- counts too.
--
-- WHAT COUNTS AS SCHEDULABLE
-- --------------------------
-- Only Execution and Assurance obligations carry a recurring cadence.
-- State, Event Response, Constraint, Evidence and Retention do not, and
-- never get a schedule. Within those two, the obligation must resolve to
-- a PERIODIC frequency (Day/Week/Month/Quarter/Year). A non-periodic
-- value -- Event Driven / Continuous / Custom -- means "no fixed cadence"
-- and drops out, which is also how an event-driven Assurance obligation
-- (trigger = Event Driven) naturally excludes itself: its frequency is
-- either absent or the non-periodic 'Event Driven' row.
--
-- FREQUENCY SOURCE (per obligation, per kind) -- same precedence as 237:
--   1. practice_instance_obligation.<kind>_frequency_id   (org override)
--   2. JSON_VALUE(pio.typed_detail_json,'$[0].<kind>_frequency_id')
--   3. published spec from vw_pm_obligation_typed_detail
--        (ExecutionSpecsJson / AssuranceSpecsJson)[0].<kind>_frequency_id
--
-- WHAT THE VIEW RETURNS
-- ---------------------
-- One row per (instance, obligation) that is schedulable, with the kind
-- and the resolved periodic frequency. The save hook (next step) upserts
-- one assurance_schedule_rule per row; the calendar reads occurrences off
-- those rules. No collapsing, no ranking -- Execution weekly and
-- Assurance monthly on the same instance are two rows here and two
-- streams on the calendar.
--
-- SAFE TO RE-RUN: CREATE OR ALTER; reads only, writes nothing.
-- DEPENDS ON: 226 (pio.execution_frequency_id / assurance_frequency_id),
--             227 (typed_detail_json), 225 (vw_pm_obligation_typed_detail),
--             frequency_master.
-- ASCII-only on purpose.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

DECLARE @prereqs_ok BIT = 1;

IF SCHEMA_ID('grac_practice') IS NULL OR OBJECT_ID('grac_practice.practice_instance_obligation','U') IS NULL
BEGIN PRINT 'ABORT (337): practice_instance_obligation missing. Run 140 first.'; SET @prereqs_ok = 0; END

IF @prereqs_ok = 1 AND OBJECT_ID('grac_practice.vw_pm_obligation_typed_detail','V') IS NULL
BEGIN PRINT 'ABORT (337): vw_pm_obligation_typed_detail missing. Run 224/225 first.'; SET @prereqs_ok = 0; END

IF @prereqs_ok = 1 AND COL_LENGTH('grac_practice.practice_instance_obligation','execution_frequency_id') IS NULL
BEGIN PRINT 'ABORT (337): pio.execution_frequency_id missing. Run 226 first.'; SET @prereqs_ok = 0; END

IF @prereqs_ok = 0
BEGIN
    RAISERROR('337_instance_schedulable_obligations: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

CREATE OR ALTER VIEW grac_practice.vw_pm_instance_schedulable_obligations
AS
    WITH candidate AS (
        -- Execution obligations: frequency from the execution column /
        -- typed detail / published execution spec.
        SELECT pio.practice_instance_id            AS PracticeInstanceId,
               pio.practice_instance_obligation_id  AS PracticeInstanceObligationId,
               pio.obligation_id                    AS ObligationId,
               N'Execution'                         AS ScheduleKind,
               COALESCE(
                   pio.execution_frequency_id,
                   TRY_CAST(JSON_VALUE(pio.typed_detail_json, N'$[0].execution_frequency_id') AS INT),
                   TRY_CAST(JSON_VALUE(td.ExecutionSpecsJson, N'$[0].execution_frequency_id') AS INT)
               )                                    AS FrequencyId
        FROM   grac_practice.practice_instance_obligation pio
        LEFT   JOIN grac_practice.vw_pm_obligation_typed_detail td
               ON td.ObligationId = pio.obligation_id
        WHERE  pio.status               = N'Active'
          AND  pio.obligation_type_code = N'Execution'

        UNION ALL

        -- Assurance obligations: frequency from the assurance column /
        -- typed detail / published assurance spec.
        SELECT pio.practice_instance_id,
               pio.practice_instance_obligation_id,
               pio.obligation_id,
               N'Assurance',
               COALESCE(
                   pio.assurance_frequency_id,
                   TRY_CAST(JSON_VALUE(pio.typed_detail_json, N'$[0].assurance_frequency_id') AS INT),
                   TRY_CAST(JSON_VALUE(td.AssuranceSpecsJson, N'$[0].assurance_frequency_id') AS INT)
               )
        FROM   grac_practice.practice_instance_obligation pio
        LEFT   JOIN grac_practice.vw_pm_obligation_typed_detail td
               ON td.ObligationId = pio.obligation_id
        WHERE  pio.status               = N'Active'
          AND  pio.obligation_type_code = N'Assurance'
    )
    SELECT c.PracticeInstanceId,
           c.PracticeInstanceObligationId,
           c.ObligationId,
           c.ScheduleKind,
           c.FrequencyId,
           fm.frequency_name AS FrequencyName
    FROM   candidate c
    JOIN   grac_practice.frequency_master fm
           ON fm.frequency_id = c.FrequencyId
          AND fm.is_active    = 1
    WHERE  c.FrequencyId IS NOT NULL
      -- Periodic only: a real recurring cadence. Non-periodic frequencies
      -- (Event Driven / Continuous / Custom, or a row with no value/unit)
      -- do not schedule.
      AND  fm.frequency_name NOT IN (N'Event Driven', N'Continuous', N'Custom')
      AND  fm.frequency_value IS NOT NULL
      AND  fm.frequency_unit  IS NOT NULL;
GO

PRINT '337: vw_pm_instance_schedulable_obligations created.';
GO

-- =====================================================================
-- Verification
-- =====================================================================
PRINT '=== 337 verification ===';

SELECT 'view created' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.vw_pm_instance_schedulable_obligations','V') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT 'emits the six expected columns',
       CASE WHEN COL_LENGTH('grac_practice.vw_pm_instance_schedulable_obligations','PracticeInstanceId')           IS NOT NULL
            AND  COL_LENGTH('grac_practice.vw_pm_instance_schedulable_obligations','PracticeInstanceObligationId') IS NOT NULL
            AND  COL_LENGTH('grac_practice.vw_pm_instance_schedulable_obligations','ObligationId')                 IS NOT NULL
            AND  COL_LENGTH('grac_practice.vw_pm_instance_schedulable_obligations','ScheduleKind')                 IS NOT NULL
            AND  COL_LENGTH('grac_practice.vw_pm_instance_schedulable_obligations','FrequencyId')                  IS NOT NULL
            AND  COL_LENGTH('grac_practice.vw_pm_instance_schedulable_obligations','FrequencyName')                IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END;

PRINT '';
PRINT '=== Schedulable obligations by kind (sample) ===';
SELECT TOP (50)
       s.PracticeInstanceId, s.PracticeInstanceObligationId, s.ObligationId,
       s.ScheduleKind, s.FrequencyName
FROM   grac_practice.vw_pm_instance_schedulable_obligations s
ORDER  BY s.PracticeInstanceId, s.ScheduleKind;

PRINT '';
PRINT '337 complete. Read by the schedule-stream upsert (next step) and by';
PRINT '        the calendar occurrence query.';
GO
SET NOEXEC OFF;
GO
