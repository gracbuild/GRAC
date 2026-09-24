-- =====================================================================
-- 351_gap_center_default_enabled_rollback.sql
--
-- Reverses 351: restores screen.gaps default to OFF and removes only the
-- explicit enable rows THIS migration inserted (entered_by = 'seed-351').
-- Rows added by 050 or by an operator are left untouched. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
GO
UPDATE grac_practice.feature_flag_master
   SET default_enabled = 0, updated_by = 'seed-351-rollback', updated_dt = SYSUTCDATETIME()
 WHERE feature_code = N'screen.gaps';

DELETE FROM grac_practice.feature_flag
WHERE  entered_by = 'seed-351'
  AND  feature_flag_id = (SELECT feature_flag_id FROM grac_practice.feature_flag_master WHERE feature_code = N'screen.gaps');
PRINT CONCAT('351 rollback: default OFF; seed-351 enable rows removed = ', @@ROWCOUNT);
GO
