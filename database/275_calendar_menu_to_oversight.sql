-- =====================================================================
-- 275 Move Calendar from Assurance to Oversight
--
-- WHAT THIS DOES
--   Re-parents the single menu row 'assurance-calendar' (menu_name
--   'Calendar') from nav-assurance to nav-oversight, and brings its
--   module_type in line with its new parent ('Assurance' -> 'Oversight').
--
--   Expected result:
--     Oversight
--         +-- Calendar
--
--   nav-assurance keeps its eleven org-assurance-* children (seeded by
--   071 / 091), so the Assurance group itself is NOT emptied or removed.
--   063 had made Calendar the sole child of nav-assurance; 071 later
--   added the Phase 2 Organization Assurance screens beside it. This
--   script only takes Calendar back out.
--
-- WHAT THIS DELIBERATELY DOES NOT DO
--   * No new menu row. menu_key is UNIQUE (uq_pm_menu_key, migration
--     022), and this is an UPDATE of the existing row keyed on that
--     value, so a second Calendar under Assurance cannot be created.
--   * No permission change. organization_role_menu_permission points at
--     menu_id, which is IDENTITY and untouched here, so every existing
--     can_view / can_add / can_edit / can_delete / can_approve grant
--     survives the move exactly as it was.
--   * No url change. menu_url stays 'Practice/Index/assurance-calendar',
--     so the existing route and the Calendar screen itself are unchanged.
--
-- DISPLAY ORDER
--   290, which places Calendar last inside Oversight, after Gap Center
--   (224), Task Center (228), My Notifications (270), Exception Centre
--   (270) and Risk Centre (280). No sibling is renumbered.
--
-- Re-runnable: yes. A second run reports 0 rows changed.
-- Rollback: database/275_calendar_menu_to_oversight_rollback.sql
-- DEPENDS ON: 022 (menu_master), 052 (nav-oversight), 063 (Calendar row).
-- ASCII-only on purpose (sqlcmd codepage safety).
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET NOEXEC OFF;
GO

-- ---------------------------------------------------------------------
-- Prerequisites
-- ---------------------------------------------------------------------
DECLARE @prereqs_ok BIT = 1;

IF SCHEMA_ID('grac_practice') IS NULL OR OBJECT_ID('grac_practice.menu_master','U') IS NULL
BEGIN PRINT 'ABORT (275): grac_practice.menu_master missing. Run 022 first.'; SET @prereqs_ok = 0; END

IF @prereqs_ok = 1 AND NOT EXISTS (SELECT 1 FROM grac_practice.menu_master WHERE menu_key = N'nav-oversight')
BEGIN PRINT 'ABORT (275): nav-oversight is missing. Run 052 first.'; SET @prereqs_ok = 0; END

IF @prereqs_ok = 1 AND NOT EXISTS (SELECT 1 FROM grac_practice.menu_master WHERE menu_key = N'assurance-calendar')
BEGIN PRINT 'ABORT (275): assurance-calendar is missing. Run 028 / 063 first.'; SET @prereqs_ok = 0; END

IF @prereqs_ok = 0
BEGIN
    RAISERROR('275_calendar_menu_to_oversight: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

-- ---------------------------------------------------------------------
-- 1. Re-parent Calendar under Oversight.
--    The WHERE clause makes the second run a no-op instead of a
--    no-change UPDATE that still stamps updated_dt.
-- ---------------------------------------------------------------------
DECLARE @oversight_id BIGINT =
    (SELECT menu_id FROM grac_practice.menu_master WHERE menu_key = N'nav-oversight');

UPDATE grac_practice.menu_master
   SET parent_menu_id = @oversight_id,
       module_type    = N'Oversight',
       display_order  = 290,
       updated_by     = N'seed-275',
       updated_dt     = SYSUTCDATETIME()
 WHERE menu_key = N'assurance-calendar'
   AND (ISNULL(parent_menu_id, -1) <> @oversight_id
        OR ISNULL(module_type, N'') <> N'Oversight'
        OR display_order <> 290);

PRINT '275: Calendar rows moved to Oversight = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

-- ---------------------------------------------------------------------
-- 2. Sanity report
-- ---------------------------------------------------------------------
SELECT 'Calendar parent is Oversight' AS Check_,
       CASE WHEN EXISTS (
                SELECT 1
                  FROM grac_practice.menu_master m
                  JOIN grac_practice.menu_master p ON p.menu_id = m.parent_menu_id
                 WHERE m.menu_key = N'assurance-calendar'
                   AND p.menu_key = N'nav-oversight')
            THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT 'No Calendar left under Assurance' AS Check_,
       CASE WHEN NOT EXISTS (
                SELECT 1
                  FROM grac_practice.menu_master m
                  JOIN grac_practice.menu_master p ON p.menu_id = m.parent_menu_id
                 WHERE p.menu_key = N'nav-assurance'
                   AND (m.menu_key = N'assurance-calendar' OR m.menu_name = N'Calendar'))
            THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT 'Assurance still has children' AS Check_,
       CASE WHEN EXISTS (
                SELECT 1
                  FROM grac_practice.menu_master m
                  JOIN grac_practice.menu_master p ON p.menu_id = m.parent_menu_id
                 WHERE p.menu_key = N'nav-assurance' AND m.status = N'Active')
            THEN 'PASS' ELSE 'FAIL (Assurance group would render empty)' END AS Result;

SELECT p.menu_key AS Parent, m.menu_key AS ChildMenu, m.menu_name AS ChildName,
       m.menu_url AS ChildUrl, m.module_type AS ModuleType,
       m.display_order AS DisplayOrder, m.status AS Status
  FROM grac_practice.menu_master m
  LEFT JOIN grac_practice.menu_master p ON p.menu_id = m.parent_menu_id
 WHERE m.menu_key = N'assurance-calendar';

PRINT '275 Calendar menu move to Oversight complete.';
GO
SET NOEXEC OFF;
GO
