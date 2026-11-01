-- =====================================================================
-- 468 Add missing foreign keys -- ROLLBACK
--
-- Drops the three FK constraints only. No data, table, or column is
-- touched, so this is always safe to run.
-- =====================================================================
SET NOCOUNT ON;
GO

IF EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_pm_asset_dup_dec_low')
    ALTER TABLE grac_practice.asset_duplicate_decision DROP CONSTRAINT fk_pm_asset_dup_dec_low;
GO
IF EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_pm_asset_dup_dec_high')
    ALTER TABLE grac_practice.asset_duplicate_decision DROP CONSTRAINT fk_pm_asset_dup_dec_high;
GO
IF EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'fk_pm_req_ctrl_correction_req')
    ALTER TABLE grac_practice.requirement_control_correction_log DROP CONSTRAINT fk_pm_req_ctrl_correction_req;
GO

SELECT '468-rollback removed' AS Check_,
       CASE WHEN NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name IN
                 ('fk_pm_asset_dup_dec_low', 'fk_pm_asset_dup_dec_high', 'fk_pm_req_ctrl_correction_req'))
            THEN 'OK' ELSE 'STILL PRESENT' END AS Result;
GO
