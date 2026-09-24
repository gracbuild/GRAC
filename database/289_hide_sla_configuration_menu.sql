-- =====================================================================
-- 289 Hide the SLA Configuration menu
--
-- WHAT THIS DOES
--   Sets menu_master.status = 'Inactive' for 'org-sla-config', so the
--   row leaves the sidebar. Same mechanism as 279 and 288.
--
-- ---------------------------------------------------------------------
-- READ THIS -- IT IS NOT THE SAME KIND OF CHANGE AS 288
-- ---------------------------------------------------------------------
-- 288 retired the Practice Instances screen after every job it held had
-- been rehomed. This one has NOT been superseded. There is no other
-- screen that configures SLA thresholds -- 'task-attributes' and
-- 'vendor-attributes' mention SLA in their descriptions but are stubs
-- (their column list is ["Id","Message"]).
--
-- And the data this screen maintains is READ AT RUNTIME, today:
--
--   184_gap_sla_match_and_override   JOIN grac_practice.org_sla_config
--                                    -- gap SLA matching and override
--   195_task_centre_v2_read          LEFT JOIN ... org_sla_config cfg
--                                    -- Task Centre due dates
--   181 / 182 / 183                  the master grid, breach events and
--                                    percentage / time-basis tuning
--   201                              notification outbox shares its
--                                    notify_event_code vocabulary
--
-- So hiding the screen does not stop SLAs working. Existing rows keep
-- driving gap matching, task due dates and notifications exactly as
-- before. What it stops is anyone TUNING them: warning and escalation
-- day thresholds, notify roles, and the adoption of new Control
-- Management SLA masters all become unreachable through the UI.
--
-- That is fine if the current configuration is settled and the screen is
-- being hidden to reduce noise. It is NOT fine if thresholds are still
-- being adjusted, or if a new SLA master is published by Control
-- Management and needs adopting -- there would be no way to do it short
-- of rolling this back or editing rows by hand.
--
-- HIDDEN, NOT DELETED -- the 279 / 288 pattern
--   Deleting the row would cascade into
--   organization_role_menu_permission and destroy every grant. Only
--   'Active' passes the sidebar and permission filters, so Inactive is
--   exactly "not shown"; the row, its menu_id and its grants survive,
--   and the rollback is a one-line status flip.
--
--   The ROUTE stays alive: PracticeController resolves screens from
--   PracticeScreen.All, not menu_master, so /Practice/org-sla-config
--   still opens for anyone with the link. That is the intended escape
--   hatch while the menu is hidden -- an administrator who needs to
--   retune can still reach it.
--
-- NO SLA DATA IS TOUCHED. menu_master only.
--
-- Re-runnable: yes. A second run reports 0 changes.
-- Rollback: database/289_hide_sla_configuration_menu_rollback.sql
-- DEPENDS ON: 180 (which seeded this menu row).
-- ALSO EDIT: 274_menu_master_seed.sql -- it is a MERGE-with-UPDATE
--            snapshot and sets this row back to Active on its next run
--            unless the same change is written there. Done in this
--            commit.
-- ASCII-only on purpose (sqlcmd codepage safety).
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET NOEXEC OFF;
GO

DECLARE @prereqs_ok BIT = 1;

IF SCHEMA_ID('grac_practice') IS NULL OR OBJECT_ID('grac_practice.menu_master','U') IS NULL
BEGIN PRINT 'ABORT (289): grac_practice.menu_master missing. Run 022 first.'; SET @prereqs_ok = 0; END

IF @prereqs_ok = 1 AND NOT EXISTS (SELECT 1 FROM grac_practice.menu_master WHERE menu_key = N'org-sla-config')
BEGIN PRINT 'ABORT (289): org-sla-config menu row not found. Run 180 first.'; SET @prereqs_ok = 0; END

IF @prereqs_ok = 0
BEGIN
    RAISERROR('289_hide_sla_configuration_menu: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

UPDATE grac_practice.menu_master
   SET status     = N'Inactive',
       updated_by = N'seed-289',
       updated_dt = SYSUTCDATETIME()
 WHERE menu_key = N'org-sla-config'
   AND status <> N'Inactive';

PRINT '289: SLA Configuration menu hidden = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

-- =====================================================================
-- Sanity report
-- =====================================================================
SELECT '289 SLA Configuration is hidden' AS Check_,
       CASE WHEN NOT EXISTS (SELECT 1 FROM grac_practice.menu_master
                              WHERE menu_key = N'org-sla-config' AND status = N'Active')
            THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT '289 menu row and grants retained' AS Check_,
       CASE WHEN EXISTS (SELECT 1 FROM grac_practice.menu_master WHERE menu_key = N'org-sla-config')
            THEN 'PASS -- '
                 + CAST((SELECT COUNT(*)
                           FROM grac_practice.organization_role_menu_permission p
                           JOIN grac_practice.menu_master m ON m.menu_id = p.menu_id
                          WHERE m.menu_key = N'org-sla-config') AS NVARCHAR(20))
                 + ' permission grant(s) kept'
            ELSE 'FAIL -- the row was deleted, not hidden' END AS Result;

-- The configuration this screen maintained is still being consumed. This
-- is not a warning that something is broken -- it is the reminder that
-- these rows now have no UI, so whoever runs 289 sees the scale of what
-- has just become read-only.
SELECT '289 SLA configuration still in use' AS Check_,
       CAST((SELECT COUNT(*) FROM grac_practice.org_sla_config) AS NVARCHAR(20))
       + ' SLA configuration row(s) remain live and are still read by'
       + ' gap matching (184) and Task Centre due dates (195)' AS Result;

PRINT '289 SLA Configuration menu hidden.';
PRINT '     Hidden, not deleted -- menu_id and every permission grant survive.';
PRINT '     The route /Practice/org-sla-config still resolves for direct links.';
PRINT '     NOTE: SLA thresholds are now untunable through the UI. Nothing is';
PRINT '           superseding this screen -- roll 289 back to restore it.';
PRINT '     REMEMBER: 274_menu_master_seed.sql carries the same change.';
GO
SET NOEXEC OFF;
GO
