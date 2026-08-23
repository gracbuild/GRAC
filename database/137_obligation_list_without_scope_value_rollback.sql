-- =====================================================================
-- 137 Obligation list without a scope value -- ROLLBACK
--
-- The procedure is CREATE OR ALTER, so rolling back means re-running 129,
-- which holds the previous body:
--
--     sqlcmd -S <server> -d <db> -i database\129_event_obligation_dedupe_procs.sql
--
-- One copy of each definition stays in the repo. Two copies drift, and the
-- stale one is always the one somebody reads.
--
-- WHAT YOU LOSE: the Role Master and Asset Category forms go back to
-- refusing to list obligations until the record has been saved once, so Add
-- shows a placeholder while Edit shows the list. The buffered ticks in the
-- form will then fail on save with THROW 67302, because the list call that
-- populates them never returns.
--
-- If you roll this back, roll back the matching Web change too, or Add mode
-- will render an editor it cannot fill.
-- =====================================================================
SET NOCOUNT ON;
GO

PRINT '137 ROLLBACK: re-run 129_event_obligation_dedupe_procs.sql to restore the pre-137 body.';
PRINT '137 ROLLBACK: Add mode in Role Master will then show a placeholder instead of the obligation list.';
GO

SELECT CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_event_obligation_mapping_list'))
                 LIKE '%THROW 67302%'
            THEN 'pre-137 body restored'
            ELSE '137 body still deployed -- re-run 129' END AS CurrentState;
GO
