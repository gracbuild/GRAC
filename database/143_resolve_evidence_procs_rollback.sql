-- =====================================================================
-- 143 Evidence resolution procedures -- ROLLBACK
--
-- Drops the two procedures. No data is touched: evidence rows keep every
-- location, locator, owner and description already filled in, so
-- re-running 143 restores full function with nothing lost.
--
-- After this rollback the workspace can still show evidence counts (those
-- come from 141) but offers no way to fill a row in.
--
-- Safe to re-run.
-- =====================================================================
SET NOCOUNT ON;
GO

IF OBJECT_ID('grac_practice.sp_resolve_evidence_save','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_resolve_evidence_save;
GO

IF OBJECT_ID('grac_practice.sp_resolve_evidence_list','P') IS NOT NULL
    DROP PROCEDURE grac_practice.sp_resolve_evidence_list;
GO

SELECT 'evidence procedures dropped' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.sp_resolve_evidence_save','P') IS NULL
             AND OBJECT_ID('grac_practice.sp_resolve_evidence_list','P') IS NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result;

-- Untouched.
SELECT COUNT(*) AS EvidenceRowsRetained
FROM   grac_practice.practice_instance_evidence
WHERE  status = N'Active';

PRINT '143 rolled back. Evidence rows and everything filled into them were left alone.';
GO
