-- =====================================================================
-- 237 Instance's effective assurance frequency, derived from obligations
--
-- WHY
-- ---
-- Phase 3 of retiring the instance-wide cadence (see 235's header). The
-- Calendar page's "Generate Assurance Schedules" flow still needs a
-- frequency per instance to seed each assurance_schedule_rule, and
-- practice_instance.assurance_frequency_id was that number.
--
-- Instance-level frequency is gone: cadence belongs to each Assurance
-- obligation on the instance. When there are two -- Weekly and Monthly
-- -- the honest single answer is the shortest cadence. Missing an
-- assurance that runs weekly because the instance was scheduled monthly
-- is a compliance gap; running it more often than needed is not.
--
-- WHAT IT DOES
-- ------------
-- Creates a view that returns, per instance, the shortest periodic
-- Assurance frequency across its adopted or self-authored Assurance
-- obligations, together with a distinct-frequency count for the UI to
-- say "derived from N obligations".
--
-- Precedence, per obligation:
--     1. pio.assurance_frequency_id                             -- organisation override
--     2. JSON_VALUE(pio.typed_detail_json, '$[0].assurance_frequency_id')
--                                                               -- authored / typed-panel edit
--     3. vw_pm_obligation_typed_detail.AssuranceSpecsJson[0].assurance_frequency_id
--                                                               -- authority's published spec
--
-- Ranking:
--     Periodic frequencies (Day/Week/Month/Quarter/Year) are normalised
--     to days. Non-periodic ones (Event Driven, Continuous, Custom) do
--     not represent a fixed cadence and are held back as a last resort.
--     Within periodic, shorter beats longer; ties break on
--     frequency_master.display_order, then id.
--
-- WHAT IT DOES NOT DO
-- -------------------
-- Nothing is dropped. practice_instance.assurance_frequency_id (and the
-- three sibling columns) stay populated by sp_practice_instance_configure
-- as before. The view is preferred by the calendar's list query; when
-- the view returns NULL the old column is still the fallback. That way
-- the older code paths in 002 / 141 / 143 / 144 / 166 that project the
-- instance column keep answering the same value they answer today.
--
-- SAFE TO RE-RUN. Requires 234 (assurance_frequency_id used as an
-- organisation override lives here) and 227 (typed_detail_json for
-- local obligations).
-- ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    PRINT 'ABORT (237): schema grac_practice missing.';
    SET NOEXEC ON;
END
GO

IF OBJECT_ID('grac_practice.practice_instance_obligation','U') IS NULL
BEGIN
    PRINT 'ABORT (237): practice_instance_obligation missing (run 140 first).';
    SET NOEXEC ON;
END
GO

IF COL_LENGTH('grac_practice.practice_instance_obligation','typed_detail_json') IS NULL
BEGIN
    PRINT 'ABORT (237): typed_detail_json missing -- run 227 first.';
    SET NOEXEC ON;
END
GO

IF COL_LENGTH('grac_practice.practice_instance_obligation','assurance_frequency_id') IS NULL
BEGIN
    PRINT 'ABORT (237): pio.assurance_frequency_id missing -- run 140 first.';
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- The view
-- =====================================================================
CREATE OR ALTER VIEW grac_practice.vw_pm_instance_effective_assurance_frequency
AS
    WITH per_obligation AS (
        -- The effective assurance frequency for each Assurance obligation
        -- on each active instance. NULL if none of the three sources
        -- names one -- for example an EventDriven Assurance with no
        -- assurance_frequency_id anywhere. Those obligations drop out
        -- during the rank because the WHERE below excludes NULLs.
        SELECT pio.practice_instance_id,
               pio.practice_instance_obligation_id,
               COALESCE(
                   pio.assurance_frequency_id,
                   TRY_CAST(JSON_VALUE(pio.typed_detail_json, N'$[0].assurance_frequency_id') AS INT),
                   pub.published_assurance_frequency_id
               ) AS assurance_frequency_id
        FROM   grac_practice.practice_instance_obligation pio
        OUTER  APPLY (
            -- Published spec, if this is an adopted obligation. The
            -- typed-detail view emits AssuranceSpecsJson from the
            -- assurance_spec table, so its first row's frequency id is
            -- what the authority wrote.
            SELECT TRY_CAST(JSON_VALUE(td.AssuranceSpecsJson, N'$[0].assurance_frequency_id') AS INT)
                       AS published_assurance_frequency_id
            FROM   grac_practice.vw_pm_obligation_typed_detail td
            WHERE  td.ObligationId = pio.obligation_id
        ) pub
        WHERE  pio.status               = N'Active'
          AND  pio.obligation_type_code = N'Assurance'
    ),
    resolved AS (
        SELECT o.practice_instance_id,
               o.assurance_frequency_id,
               fm.frequency_name,
               fm.display_order,
               -- Periodic cadence in days. NULL for non-periodic ones so
               -- they rank last, regardless of frequency_value.
               CASE
                 WHEN fm.frequency_name IN (N'Event Driven', N'Continuous', N'Custom')
                      THEN NULL
                 WHEN fm.frequency_value IS NULL OR fm.frequency_unit IS NULL
                      THEN NULL
                 ELSE fm.frequency_value
                      * CASE UPPER(LTRIM(RTRIM(fm.frequency_unit)))
                             WHEN N'DAY'     THEN 1
                             WHEN N'DAYS'    THEN 1
                             WHEN N'WEEK'    THEN 7
                             WHEN N'WEEKS'   THEN 7
                             WHEN N'MONTH'   THEN 30
                             WHEN N'MONTHS'  THEN 30
                             WHEN N'QUARTER' THEN 90
                             WHEN N'QUARTERS'THEN 90
                             WHEN N'YEAR'    THEN 365
                             WHEN N'YEARS'   THEN 365
                             ELSE NULL
                        END
               END AS periodic_days
        FROM   per_obligation o
        JOIN   grac_practice.frequency_master fm
               ON fm.frequency_id = o.assurance_frequency_id
              AND fm.is_active    = 1
        WHERE  o.assurance_frequency_id IS NOT NULL
    ),
    ranked AS (
        SELECT practice_instance_id, assurance_frequency_id, frequency_name,
               ROW_NUMBER() OVER (
                   PARTITION BY practice_instance_id
                   ORDER BY CASE WHEN periodic_days IS NULL THEN 1 ELSE 0 END,
                            periodic_days,
                            display_order,
                            assurance_frequency_id
               ) AS rn
        FROM   resolved
    )
    SELECT r.practice_instance_id                                          AS PracticeInstanceId,
           MAX(CASE WHEN r.rn = 1 THEN r.assurance_frequency_id END)       AS AssuranceFrequencyId,
           MAX(CASE WHEN r.rn = 1 THEN r.frequency_name         END)       AS AssuranceFrequency,
           COUNT(DISTINCT r.assurance_frequency_id)                        AS DistinctFrequencyCount,
           COUNT(*)                                                        AS ObligationCount
    FROM   ranked r
    GROUP  BY r.practice_instance_id;
GO

PRINT '237: vw_pm_instance_effective_assurance_frequency created.';
GO

-- =====================================================================
-- Verification
-- =====================================================================
PRINT '=== 237 verification ===';

SELECT 'view created' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.vw_pm_instance_effective_assurance_frequency','V') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT 'view returns the four expected columns',
       CASE WHEN COL_LENGTH('grac_practice.vw_pm_instance_effective_assurance_frequency','PracticeInstanceId')      IS NOT NULL
            AND  COL_LENGTH('grac_practice.vw_pm_instance_effective_assurance_frequency','AssuranceFrequencyId')    IS NOT NULL
            AND  COL_LENGTH('grac_practice.vw_pm_instance_effective_assurance_frequency','AssuranceFrequency')      IS NOT NULL
            AND  COL_LENGTH('grac_practice.vw_pm_instance_effective_assurance_frequency','DistinctFrequencyCount')  IS NOT NULL
            AND  COL_LENGTH('grac_practice.vw_pm_instance_effective_assurance_frequency','ObligationCount')         IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END;

-- What each instance now says its effective assurance frequency is, and
-- what its stored column says. A mismatch is not a fault -- it is exactly
-- what this migration exists to reveal.
PRINT '';
PRINT '=== Instance-vs-derived assurance frequency ===';
SELECT pi.practice_instance_id AS PracticeInstanceId,
       pi.instance_code        AS InstanceCode,
       ef.AssuranceFrequency   AS EffectiveAssuranceFrequency,
       ef.DistinctFrequencyCount AS DistinctFrequencies,
       ef.ObligationCount      AS AssuranceObligations,
       oldfm.frequency_name    AS StoredOnInstance
FROM   grac_practice.practice_instance pi
LEFT   JOIN grac_practice.vw_pm_instance_effective_assurance_frequency ef
       ON ef.PracticeInstanceId = pi.practice_instance_id
LEFT   JOIN grac_practice.frequency_master oldfm
       ON oldfm.frequency_id = pi.assurance_frequency_id
WHERE  pi.status = N'Active'
ORDER  BY pi.practice_instance_id;

PRINT '';
PRINT '237 complete. Ship PracticeManagement.Api with it (the calendar list';
PRINT '        query in PracticeRepositoryService uses this view).';
GO

SET NOEXEC OFF;
GO
