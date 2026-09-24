-- =====================================================================
-- 351_gap_center_default_enabled.sql
--
-- SYMPTOM
--   "Gap Center is not yet enabled" for an organization.
--
-- CAUSE
--   Gap Center is gated by feature flag 'screen.gaps'
--   (feature_flag_master.default_enabled = 0). Migration 050 enabled it
--   by inserting a per-org feature_flag row FOR EVERY ORG THAT EXISTED
--   AT THE TIME. Any organization created AFTER 050 ran has no row, so
--   fn_pm_feature_enabled falls back to the master default (0 = OFF) and
--   the screen reports "not yet enabled".
--
-- FIX (durable)
--   1. Set feature_flag_master.default_enabled = 1 for 'screen.gaps', so
--      every org without an explicit override -- current new orgs AND all
--      future orgs -- inherits Gap Center as ON.
--   2. Also insert an explicit enable row for any EXISTING org that has no
--      feature_flag row yet (belt and suspenders; makes it visible in the
--      per-org table). Orgs that were DELIBERATELY disabled keep their
--      is_enabled = 0 row untouched -- this migration never flips an
--      existing row.
--
-- SAFE TO RE-RUN. ASCII-only.
-- Rollback: 351_gap_center_default_enabled_rollback.sql
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.feature_flag_master','U') IS NULL
   OR OBJECT_ID('grac_practice.feature_flag','U') IS NULL
BEGIN
    RAISERROR('351: feature_flag tables missing -- run 041 first.', 16, 1);
END
GO

DECLARE @gaps_feature_id INT =
    (SELECT feature_flag_id FROM grac_practice.feature_flag_master WHERE feature_code = N'screen.gaps');

IF @gaps_feature_id IS NULL
BEGIN
    RAISERROR('351: feature ''screen.gaps'' is not registered -- run 050 first.', 16, 1);
END
ELSE
BEGIN
    -- 1. Default ON for every org without an override (current + future).
    UPDATE grac_practice.feature_flag_master
       SET default_enabled = 1,
           updated_by       = 'seed-351',
           updated_dt       = SYSUTCDATETIME()
     WHERE feature_code = N'screen.gaps'
       AND default_enabled <> 1;
    PRINT CONCAT('351: screen.gaps default_enabled set ON (rows changed = ', @@ROWCOUNT, ').');

    -- 2. Explicit enable row for existing orgs that have none. Never
    --    touches an org that already has a row (deliberate enable OR
    --    disable is preserved).
    MERGE grac_practice.feature_flag AS target
    USING (SELECT o.organization_id, @gaps_feature_id AS feature_flag_id
           FROM   grac_practice.organization o) AS source
       ON target.organization_id = source.organization_id
      AND target.feature_flag_id = source.feature_flag_id
    WHEN NOT MATCHED BY TARGET THEN
        INSERT (organization_id, feature_flag_id, is_enabled, notes, entered_by)
        VALUES (source.organization_id, source.feature_flag_id, 1, N'Enabled by seed-351', 'seed-351');
    PRINT CONCAT('351: explicit enable rows added for orgs that lacked one (rows = ', @@ROWCOUNT, ').');
END
GO

PRINT '=== 351 verification ===';
SELECT default_enabled AS ScreenGaps_DefaultEnabled
FROM   grac_practice.feature_flag_master
WHERE  feature_code = N'screen.gaps';
GO
PRINT '351: Gap Center (screen.gaps) is enabled by default for all organizations.';
GO
