-- =====================================================================
-- 114 Backfill: generate a custom_gap row for every already-Accepted
-- Assurance observation that doesn't have one.
--
-- Why this is needed:
--   The auto-hook added in 105/112 fires only when
--   sp_org_assurance_observation_accept runs. Observations that were
--   Accepted BEFORE migration 112 landed never triggered the hook,
--   so their gaps were never created.
--
-- What this migration does:
--   1. Reports the pre-backfill gap counts by source.
--   2. Iterates every active observation currently in status
--      'Accepted' that has no active junction row and no legacy
--      observation.gap_id pointing at an active custom_gap.
--   3. Calls sp_custom_gap_generate_from_assurance_observation for
--      each -- that SP is idempotent, so a re-run of 114 is safe.
--   4. Reports the post-backfill counts.
--
-- IDEMPOTENT -- safe to run multiple times. Only observations
-- missing a gap will get one.
--
-- Rollback: 114 has no rollback (backfilled rows are indistinguishable
-- from any other auto-generated row and are legitimate data).
-- If you must undo, use 111's destructive rollback which removes any
-- source_reference_type='AssuranceObservation' rows (but that also
-- deletes anything created by user action, not just this backfill).
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.sp_custom_gap_generate_from_assurance_observation','P') IS NULL
BEGIN
    RAISERROR('114: sp_custom_gap_generate_from_assurance_observation missing -- run migration 112 first.', 16, 1);
    RETURN;
END
IF OBJECT_ID('grac_practice.org_assurance_observation','U') IS NULL
   OR OBJECT_ID('grac_practice.org_assurance_observation_status_master','U') IS NULL
BEGIN
    RAISERROR('114: assurance observation tables missing -- run migrations 101 + 102 first.', 16, 1);
    RETURN;
END
GO

-- =====================================================================
-- Pre-run diagnostic snapshot
-- =====================================================================
PRINT '--- 114 pre-backfill snapshot ---';

SELECT 'Accepted observations (any org)' AS Metric,
       COUNT(*) AS Value
FROM grac_practice.org_assurance_observation o
JOIN grac_practice.org_assurance_observation_status_master s
     ON s.org_assurance_observation_status_id = o.observation_status_id
WHERE o.is_active = 1 AND s.status_code = N'Accepted';

SELECT 'Accepted observations WITHOUT active gap junction' AS Metric,
       COUNT(*) AS Value
FROM grac_practice.org_assurance_observation o
JOIN grac_practice.org_assurance_observation_status_master s
     ON s.org_assurance_observation_status_id = o.observation_status_id
WHERE o.is_active = 1 AND s.status_code = N'Accepted'
  AND NOT EXISTS (
      SELECT 1 FROM grac_practice.custom_gap_observation j
      WHERE j.org_assurance_observation_id = o.org_assurance_observation_id
        AND j.is_active = 1);

SELECT 'custom_gap rows source=Assurance (not Cancelled)' AS Metric,
       COUNT(*) AS Value
FROM grac_practice.custom_gap
WHERE gap_source_module_code = N'Assurance'
  AND status <> N'Cancelled';
GO

-- =====================================================================
-- Backfill loop
-- =====================================================================
DECLARE @backfilled INT = 0;
DECLARE @failed     INT = 0;

DECLARE @obs_id BIGINT, @org_id BIGINT, @new_gap_id BIGINT;

DECLARE cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT o.org_assurance_observation_id, o.organization_id
    FROM grac_practice.org_assurance_observation o
    JOIN grac_practice.org_assurance_observation_status_master s
         ON s.org_assurance_observation_status_id = o.observation_status_id
    WHERE o.is_active = 1
      AND s.status_code = N'Accepted'
      AND NOT EXISTS (
          SELECT 1 FROM grac_practice.custom_gap_observation j
          WHERE j.org_assurance_observation_id = o.org_assurance_observation_id
            AND j.is_active = 1);

OPEN cur;
FETCH NEXT FROM cur INTO @obs_id, @org_id;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        SET @new_gap_id = NULL;
        EXEC grac_practice.sp_custom_gap_generate_from_assurance_observation
             @organization_id  = @org_id,
             @observation_id   = @obs_id,
             @actor            = 'backfill-114',
             @custom_gap_id_out = @new_gap_id OUTPUT;
        SET @backfilled = @backfilled + 1;
    END TRY
    BEGIN CATCH
        SET @failed = @failed + 1;
        PRINT N'114: obs #' + CAST(@obs_id AS NVARCHAR(20)) +
              N' FAILED: ' + ERROR_MESSAGE();
    END CATCH
    FETCH NEXT FROM cur INTO @obs_id, @org_id;
END
CLOSE cur; DEALLOCATE cur;

PRINT '--- 114 backfill result ---';
PRINT 'observations backfilled: ' + CAST(@backfilled AS NVARCHAR(20));
PRINT 'observations failed    : ' + CAST(@failed     AS NVARCHAR(20));
GO

-- =====================================================================
-- Post-run diagnostic snapshot
-- =====================================================================
PRINT '--- 114 post-backfill snapshot ---';

SELECT 'custom_gap rows source=Assurance (not Cancelled)' AS Metric,
       COUNT(*) AS Value
FROM grac_practice.custom_gap
WHERE gap_source_module_code = N'Assurance'
  AND status <> N'Cancelled';

SELECT 'Accepted observations STILL without active gap (should be 0)' AS Metric,
       COUNT(*) AS Value
FROM grac_practice.org_assurance_observation o
JOIN grac_practice.org_assurance_observation_status_master s
     ON s.org_assurance_observation_status_id = o.observation_status_id
WHERE o.is_active = 1 AND s.status_code = N'Accepted'
  AND NOT EXISTS (
      SELECT 1 FROM grac_practice.custom_gap_observation j
      WHERE j.org_assurance_observation_id = o.org_assurance_observation_id
        AND j.is_active = 1);
GO

PRINT '114 Assurance-observation backfill complete.';
GO
