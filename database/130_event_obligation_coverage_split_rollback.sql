-- =====================================================================
-- 130 Coverage split -- ROLLBACK
--
-- The procedure is CREATE OR ALTER, so rolling back means re-running 128
-- (or 129, which does not touch this procedure):
--
--     sqlcmd -S <server> -d <db> -i database\128_event_obligation_scope_procs.sql
--
-- One copy of each definition stays in the repo -- two copies drift, and
-- the stale one is always the one someone reads.
--
-- WHAT YOU LOSE: the ApplicableObligations / ExcludedObligations columns.
-- The screen then shows only "decided", so a role whose every obligation
-- has been excluded reads as 100% covered. That is the confusion 130
-- exists to remove. The Web partial tolerates the columns being absent
-- (it falls back to the decided figure), so the UI will not break -- it
-- just stops telling you how many obligations actually apply.
-- =====================================================================
SET NOCOUNT ON;
GO

PRINT '130 ROLLBACK: re-run 128_event_obligation_scope_procs.sql to restore the pre-130 coverage procedure.';
PRINT '130 ROLLBACK: the screen will then show "decided" only -- 100% can mean "everything excluded".';
GO

-- Verification aid: roles where every decided obligation has been excluded.
-- Under the pre-130 procedure each of these shows as 100%.
IF OBJECT_ID('grac_practice.event_obligation_applicability','U') IS NOT NULL
    SELECT a.organization_id,
           r.role_name                                                        AS RoleName,
           COUNT(DISTINCT a.obligation_id)                                    AS Decided,
           COUNT(DISTINCT CASE WHEN a.is_applicable = 1 THEN a.obligation_id END) AS Applicable
    FROM   grac_practice.event_obligation_applicability a
    JOIN   grac_practice.organization_role r ON r.role_id = a.scope_role_id
    WHERE  a.status = N'Active'
    GROUP BY a.organization_id, r.role_name
    HAVING COUNT(DISTINCT CASE WHEN a.is_applicable = 1 THEN a.obligation_id END) = 0
    ORDER BY a.organization_id, r.role_name;
GO
