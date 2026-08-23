-- =====================================================================
-- 113 Retire the parallel org_assurance_gap module now that its data
-- has been migrated into custom_gap (see 111) and its API/UI have been
-- retargeted.
--
-- What this drops:
--   1. All sp_org_assurance_gap_* procedures (from 105/108).
--   2. Table org_assurance_gap_observation (junction rewritten in 110).
--   3. Table org_assurance_gap_action.
--   4. Table org_assurance_gap_history.
--   5. Table org_assurance_gap.
--   6. Table org_assurance_gap_status_master.
--   7. Menu row org-assurance-gaps + its permissions.
--   8. Feature flag rows for screen.org-assurance-gaps.
--   9. Feature flag master row.
--
-- What survives:
--   * observation.gap_id column stays (retargeted to custom_gap_id
--     during 111, still used as a "primary gap" backward-compat pointer).
--   * The 105-defined sp_org_assurance_observation_accept was
--     rewritten in 112 to call sp_custom_gap_generate_from_assurance_observation.
--
-- Rollback: 113_org_assurance_gap_retire_rollback.sql
--           (best-effort -- some data is genuinely gone once tables
--           are dropped; only useful for menu / flag restoration.
--           If you must rehydrate tables, restore from a backup and
--           re-run 111 in reverse.)
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

BEGIN TRAN;

-- =====================================================================
-- 1. Drop parallel procedures.
-- =====================================================================
DROP PROCEDURE IF EXISTS grac_practice.sp_org_assurance_gap_history_list;
DROP PROCEDURE IF EXISTS grac_practice.sp_org_assurance_gap_action_delete;
DROP PROCEDURE IF EXISTS grac_practice.sp_org_assurance_gap_action_complete;
DROP PROCEDURE IF EXISTS grac_practice.sp_org_assurance_gap_action_save;
DROP PROCEDURE IF EXISTS grac_practice.sp_org_assurance_gap_action_list;
DROP PROCEDURE IF EXISTS grac_practice.sp_org_assurance_gap_reopen;
DROP PROCEDURE IF EXISTS grac_practice.sp_org_assurance_gap_close;
DROP PROCEDURE IF EXISTS grac_practice.sp_org_assurance_gap_verify;
DROP PROCEDURE IF EXISTS grac_practice.sp_org_assurance_gap_submit_remediation;
DROP PROCEDURE IF EXISTS grac_practice.sp_org_assurance_gap_start;
DROP PROCEDURE IF EXISTS grac_practice.sp_org_assurance_gap_transition;
DROP PROCEDURE IF EXISTS grac_practice.sp_org_assurance_gap_generate_from_observation;
DROP PROCEDURE IF EXISTS grac_practice.sp_org_assurance_gap_merge;
DROP PROCEDURE IF EXISTS grac_practice.sp_org_assurance_observation_linked_gaps_list;
DROP PROCEDURE IF EXISTS grac_practice.sp_org_assurance_gap_observation_list;
DROP PROCEDURE IF EXISTS grac_practice.sp_org_assurance_gap_observation_detach;
DROP PROCEDURE IF EXISTS grac_practice.sp_org_assurance_gap_observation_attach;
DROP PROCEDURE IF EXISTS grac_practice.sp_org_assurance_gap_delete;
DROP PROCEDURE IF EXISTS grac_practice.sp_org_assurance_gap_save;
DROP PROCEDURE IF EXISTS grac_practice.sp_org_assurance_gap_get;
DROP PROCEDURE IF EXISTS grac_practice.sp_org_assurance_gap_list;
DROP PROCEDURE IF EXISTS grac_practice.sp_org_assurance_gap_status_list;
GO

-- =====================================================================
-- 2. Drop parallel tables (order matters -- children first).
-- =====================================================================
IF OBJECT_ID('grac_practice.org_assurance_gap_history','U') IS NOT NULL
    DROP TABLE grac_practice.org_assurance_gap_history;
IF OBJECT_ID('grac_practice.org_assurance_gap_action','U') IS NOT NULL
    DROP TABLE grac_practice.org_assurance_gap_action;
IF OBJECT_ID('grac_practice.org_assurance_gap_observation','U') IS NOT NULL
    DROP TABLE grac_practice.org_assurance_gap_observation;
IF OBJECT_ID('grac_practice.org_assurance_gap','U') IS NOT NULL
    DROP TABLE grac_practice.org_assurance_gap;
IF OBJECT_ID('grac_practice.org_assurance_gap_status_master','U') IS NOT NULL
    DROP TABLE grac_practice.org_assurance_gap_status_master;
GO

-- =====================================================================
-- 3. Retire the parallel menu row + permissions + feature flags.
-- =====================================================================
IF EXISTS (SELECT 1 FROM grac_practice.menu_master WHERE menu_key = N'org-assurance-gaps')
BEGIN
    DELETE FROM grac_practice.feature_flag
    WHERE feature_flag_id IN (
        SELECT feature_flag_id FROM grac_practice.feature_flag_master
        WHERE feature_code = N'screen.org-assurance-gaps');

    DELETE FROM grac_practice.organization_role_menu_permission
    WHERE menu_id IN (SELECT menu_id FROM grac_practice.menu_master
                      WHERE menu_key = N'org-assurance-gaps');

    DELETE FROM grac_practice.menu_master
    WHERE menu_key = N'org-assurance-gaps';

    DELETE FROM grac_practice.feature_flag_master
    WHERE feature_code = N'screen.org-assurance-gaps';
END
GO

COMMIT TRAN;
GO

-- =====================================================================
-- Sanity report
-- =====================================================================
SELECT 'org_assurance_gap table dropped' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.org_assurance_gap','U') IS NULL THEN 'PASS' ELSE 'FAIL' END AS Result;
SELECT 'org-assurance-gaps menu row removed' AS Check_,
       CASE WHEN NOT EXISTS (SELECT 1 FROM grac_practice.menu_master
                             WHERE menu_key = N'org-assurance-gaps')
            THEN 'PASS' ELSE 'FAIL' END AS Result;
SELECT 'observation.gap_id column still present (compat)' AS Check_,
       CASE WHEN COL_LENGTH('grac_practice.org_assurance_observation','gap_id') IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;

PRINT '113 Retirement of org_assurance_gap module complete.';
GO

SET NOEXEC OFF;
GO
