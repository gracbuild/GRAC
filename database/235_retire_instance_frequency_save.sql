-- =====================================================================
-- 235 Retire the instance-level "Save frequency" flow
--
-- WHY
-- ---
-- Frequency is a property of an obligation, not of the practice instance.
-- Only Execution and Assurance obligations have one; State, Constraint,
-- EventResponse etc. do not -- so a single instance-wide cadence had no
-- honest answer on a mixed set. The Operationalize page's "Save
-- frequency" box was retired, and every editor for cadence now lives
-- inside the obligation card next to the field it overrides (migrations
-- 234 and the JS changes that shipped with it).
--
-- The stored procedure that saved the instance frequency is now dead
-- code: no code path calls it. This migration drops it.
--
-- WHAT IT DOES NOT DO
-- -------------------
-- The four columns on practice_instance stay:
--
--     execution_frequency_id, assurance_frequency_id,
--     frequency_id, frequency_type
--
-- and sp_practice_instance_configure keeps populating them from the
-- practice's obligation defaults. The Calendar page's assurance-schedule
-- generator (029) reads pi.assurance_frequency_id to seed
-- assurance_schedule_rule, and taking the columns away would leave that
-- workflow with nothing to key off. Rewiring the calendar to derive
-- cadence from each obligation is Phase 3, not this one.
--
-- OTHER LEGACY READ SITES
-- -----------------------
-- 002 monolith, 017 normalisation, 141 old resolve-workspace procs, 143
-- old evidence procs, 166 exception centre v2, and
-- PracticeRepositoryService.cs L2233+ all still project the four columns.
-- None of those callers write; they just carry the value through the
-- older list/detail shapes. Leaving the columns populated keeps their
-- output the same as today's.
--
-- SAFE TO RE-RUN. Requires 145 (which created the procedure).
-- ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    PRINT 'ABORT (235): schema grac_practice missing.';
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- Drop the procedure
-- =====================================================================
IF OBJECT_ID('grac_practice.sp_resolve_instance_frequency_save','P') IS NOT NULL
BEGIN
    DROP PROCEDURE grac_practice.sp_resolve_instance_frequency_save;
    PRINT '235: sp_resolve_instance_frequency_save dropped.';
END
ELSE
BEGIN
    PRINT '235: sp_resolve_instance_frequency_save was already absent (nothing to do).';
END
GO

-- =====================================================================
-- Verification
-- =====================================================================
PRINT '=== 235 verification ===';

SELECT 'save procedure dropped' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.sp_resolve_instance_frequency_save','P') IS NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
-- The columns must survive: the Configure default and the Calendar
-- generator both depend on them.
SELECT 'execution_frequency_id column kept',
       CASE WHEN COL_LENGTH('grac_practice.practice_instance','execution_frequency_id') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL -- column disappeared, Calendar generator will break' END
UNION ALL
SELECT 'assurance_frequency_id column kept',
       CASE WHEN COL_LENGTH('grac_practice.practice_instance','assurance_frequency_id') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL -- column disappeared, Calendar generator will break' END
UNION ALL
SELECT 'Configure still populates the frequency',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_practice_instance_configure','P'))
                 LIKE '%vw_pm_practice_default_frequency%'
            THEN 'PASS' ELSE 'FAIL -- new instances would land without a cadence' END
UNION ALL
-- If any procedure still names the dropped one, it would fail at the
-- next invocation. This surfaces such a caller now.
SELECT 'no procedure still calls the dropped one',
       CASE WHEN NOT EXISTS (
            SELECT 1 FROM sys.sql_modules
             WHERE definition LIKE '%sp_resolve_instance_frequency_save%')
            THEN 'PASS' ELSE 'FAIL -- see the query below' END;

-- If the last check fails, this lists which procedures still mention it.
SELECT OBJECT_SCHEMA_NAME(m.object_id) + '.' + OBJECT_NAME(m.object_id) AS StillCalls
FROM   sys.sql_modules m
WHERE  m.definition LIKE '%sp_resolve_instance_frequency_save%';

PRINT '';
PRINT '235 complete. Ship PracticeManagement.Api and PracticeManagement.Web with it.';
GO

SET NOEXEC OFF;
GO
