-- =====================================================================
-- 319 Gap lifecycle: re-assert "Delegated" -> "Analysed" display name
--
-- SIR'S FEEDBACK
-- ---------------
-- "deligated nnu oru status ipo kanikunnundallo." -- a status called
-- "Delegated" is now showing (in the Gap Centre list's Status column,
-- after 318 started reading the lifecycle stage there).
--
-- ROOT CAUSE
-- ----------
-- 318 reads gap_lifecycle_state_master.state_name for the Status column,
-- exactly the same column sp_custom_gap_header already reads for the
-- gap-detail screen. That is the right column -- the bug is not in 318 --
-- but the DATA in it, on this database, is stale.
--
-- 175 (gap_terminology_and_ui_tighten) renamed state_name from
-- 'Delegated' to 'Analysed' for state_code = 'Delegated' -- "Delegated"
-- read as internal jargon to an operator. 174, which first created that
-- row, seeded it with state_name = 'Delegated' (same as its state_code).
-- 272 (master_data_seed) ALSO carries a seed row for state_code =
-- 'Delegated' with state_name = 'Delegated' -- 272 was written copying
-- 174's original literal and never updated after 175 renamed it. 272's
-- MERGE is insert-only (WHEN NOT MATCHED BY TARGET, no WHEN MATCHED),
-- so it cannot silently revert an already-renamed row -- but if
-- gap_lifecycle_state_master was ever empty when 272 ran (a fresh
-- database, or a data reset that cleared it) and 175 was not re-applied
-- afterward, 272 inserts the row with the stale 'Delegated' name and it
-- stays that way until 175 runs (or re-runs) again.
--
-- Net effect: on THIS database, right now, state_name for state_code =
-- 'Delegated' reads literally 'Delegated' -- so 318, correctly, shows
-- exactly what is in the table.
--
-- WHAT THIS DOES
-- --------------
-- Re-applies 175's own rename -- the identical UPDATE, safe to run
-- whether or not 175 already ran (a same-value UPDATE is a no-op) --
-- so the live data is correct after this migration regardless of which
-- of the above histories actually happened. No proc, no view, no other
-- object changes; 318's sp_gap_centre_list is untouched (it was already
-- correct) and needs no re-issue.
--
-- 174.sql and 272.sql are left exactly as they are -- this session's
-- migrations are an append-only history, so an earlier migration's
-- seed literal is not edited after the fact. 175 is already the
-- correction layer for that literal; 319 exists only because 175's
-- effect did not (or no longer does) hold on this specific database.
--
-- IF THIS RECURS: after any future practice-data reset that reseeds
-- masters via 272 from empty, re-run 175 (or this file) afterward,
-- before relying on the Gap Centre Status column again.
--
-- Rollback: 319_gap_lifecycle_delegated_display_name_reassert_rollback.sql
-- (restores state_name back to 'Delegated', matching 174/272's literal --
-- i.e. undoes 175's rename too, which is what 175's own rollback does;
-- provided for symmetry with every other migration pair in this project,
-- not because anyone is expected to want it back).
-- SAFE TO RE-RUN. ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

DECLARE @ok BIT = 1;
IF SCHEMA_ID('grac_practice') IS NULL
BEGIN PRINT 'ABORT (319): schema grac_practice missing.'; SET @ok = 0; END
IF OBJECT_ID('grac_practice.gap_lifecycle_state_master','U') IS NULL
BEGIN PRINT 'ABORT (319): gap_lifecycle_state_master missing (run 156 first).'; SET @ok = 0; END
IF @ok = 0
BEGIN
    RAISERROR('319_gap_lifecycle_delegated_display_name_reassert: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

UPDATE grac_practice.gap_lifecycle_state_master
   SET state_name  = N'Analysed',
       description = N'Analysis complete; downstream Task / Exception / Risk artefacts own the remediation. Terminal from Gap Centre.',
       updated_by  = N'seed-319',
       updated_dt  = SYSUTCDATETIME()
 WHERE state_code = N'Delegated'
   AND state_name <> N'Analysed';
GO
PRINT '319: gap_lifecycle_state_master.state_name for Delegated re-asserted to Analysed.';
GO

-- =====================================================================
-- Verification
-- =====================================================================
PRINT '=== 319 verification ===';

SELECT '319-a Delegated state exists' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM grac_practice.gap_lifecycle_state_master WHERE state_code = N'Delegated')
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '319-b its state_name is now Analysed',
       CASE WHEN EXISTS (SELECT 1 FROM grac_practice.gap_lifecycle_state_master
                           WHERE state_code = N'Delegated' AND state_name = N'Analysed')
            THEN 'PASS' ELSE 'FAIL' END;

PRINT '';
PRINT '--- Current gap_lifecycle_state_master rows (what Gap Centre / gap-detail can show) ---';
SELECT state_code, state_name, is_terminal, is_valid_terminal, status
  FROM grac_practice.gap_lifecycle_state_master
 ORDER BY sort_order;

PRINT '';
PRINT '--- Spot check: gaps currently in each lifecycle state ---';
SELECT s.state_name, COUNT(*) AS GapCount
  FROM grac_practice.custom_gap cg
  LEFT JOIN grac_practice.gap_lifecycle_state_master s ON s.lifecycle_state_id = cg.lifecycle_state_id
 GROUP BY s.state_name
 ORDER BY GapCount DESC;

PRINT '';
PRINT '319 complete. Delegated displays as Analysed everywhere that reads state_name.';
GO

SET NOEXEC OFF;
