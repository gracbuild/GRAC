-- =====================================================================
-- 495_custom_gap_edit_rollback.sql
--
-- Drops grac_practice.sp_custom_gap_edit. Edits already made stay (they
-- are ordinary values in custom_gap / custom_gap_practice_map, and their
-- EDIT rows in custom_gap_history). The API answers the edit route with
-- the SQL error until the procedure is back; deploy the previous Web to
-- hide the Edit item. SAFE TO RE-RUN. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
GO
DROP PROCEDURE IF EXISTS grac_practice.sp_custom_gap_edit;
GO
SELECT '495 rollback: sp_custom_gap_edit dropped' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.sp_custom_gap_edit','P') IS NULL THEN 'PASS' ELSE 'FAIL' END AS Result_;
GO
