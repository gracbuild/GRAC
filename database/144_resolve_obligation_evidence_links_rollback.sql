-- =====================================================================
-- 144 -- ROLLBACK
--
-- Drops the obligation-evidence view. It does NOT re-emit 141's versions
-- of sp_resolve_obligation_list / sp_resolve_obligation_adopt, because
-- those procedures read evidence from the direct table only -- the defect
-- 144 exists to correct. Rolling back to them would make linked evidence
-- invisible again.
--
-- If that really is what you want, run 141_resolve_workspace_procs.sql;
-- it is CREATE OR ALTER and will replace both procedures. Drop the view
-- afterwards, not before, or the replacements will fail to compile while
-- the current ones still reference it.
--
-- No data is touched. The source_obligation_id values the backfill set
-- stay: they say which obligation an evidence row belongs to, and that
-- is true regardless of which procedure reads it.
--
-- Safe to re-run.
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.sp_resolve_obligation_adopt','P') IS NOT NULL
   AND OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_resolve_obligation_adopt'))
       LIKE '%vw_pm_obligation_evidence%'
BEGIN
    PRINT 'ABORT: sp_resolve_obligation_adopt still reads vw_pm_obligation_evidence.';
    PRINT 'Run 141_resolve_workspace_procs.sql first, then re-run this rollback.';
END
ELSE
BEGIN
    IF OBJECT_ID('grac_practice.vw_pm_obligation_evidence','V') IS NOT NULL
        DROP VIEW grac_practice.vw_pm_obligation_evidence;
    PRINT '144 rolled back: the obligation evidence view was dropped.';
END
GO

SELECT 'view state' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.vw_pm_obligation_evidence','V') IS NULL
            THEN 'dropped' ELSE 'still present (procedures still use it)' END AS Result;

-- Attachments the backfill made are left in place.
SELECT COUNT(*) AS EvidenceRowsAttachedToAnObligation
FROM   grac_practice.practice_instance_evidence
WHERE  status = N'Active' AND source_obligation_id IS NOT NULL;
GO
