-- =====================================================================
-- 129 Obligation resolver de-duplication -- ROLLBACK
--
-- Both procedures are CREATE OR ALTER, so rolling back means re-running
-- 128, which redefines them to their pre-129 bodies.
--
--     sqlcmd -S <server> -d <db> -i database\128_event_obligation_scope_procs.sql
--
-- Doing it that way rather than pasting the old bodies here keeps one copy
-- of each definition in the repo -- two copies drift, and the stale one is
-- always the one someone reads.
--
-- BE AWARE OF WHAT YOU ARE RESTORING. The 128 bodies have two known
-- defects that 129 exists to fix:
--   * the mapping list returns one row per path an obligation takes to the
--     organization, so obligations appear two or more times on screen;
--   * sp_event_obligation_raise inserts into a table variable keyed on
--     obligation_id, so any duplicate path -- or an employee holding two
--     roles that map the same obligation -- raises a primary key violation
--     and the raise fails.
-- =====================================================================
SET NOCOUNT ON;
GO

PRINT '129 ROLLBACK: re-run 128_event_obligation_scope_procs.sql to restore the pre-129 procedure bodies.';
PRINT '129 ROLLBACK: doing so reintroduces duplicate rows on the mapping screen and the';
PRINT '              primary key violation in sp_event_obligation_raise. See the header of this file.';
GO

-- Verification aid: how many duplicate paths exist right now. If this
-- returns rows, the 128 bodies will duplicate them on screen.
IF OBJECT_ID('grac_practice.vw_pm_event_driven_obligation','V') IS NOT NULL
    SELECT organization_id,
           obligation_id,
           event_type_code                             AS EventTypeCode,
           COUNT(*)                                    AS ViewRows,
           COUNT(DISTINCT organization_requirement_id) AS RequirementPaths,
           COUNT(DISTINCT practice_id)                 AS Practices,
           COUNT(DISTINCT release_id)                  AS Releases
    FROM   grac_practice.vw_pm_event_driven_obligation
    GROUP BY organization_id, obligation_id, event_type_code
    HAVING COUNT(*) > 1
    ORDER BY ViewRows DESC;
GO
