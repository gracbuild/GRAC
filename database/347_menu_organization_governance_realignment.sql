-- =====================================================================
-- 347 Organization branch realignment + Oversight/Audit Management order
--
-- WHAT HAPPENED
--   274_menu_master_seed.sql was edited 2026-09-15 and re-run. Being a
--   MERGE-with-UPDATE snapshot, it brought every one of its 98 tracked
--   rows back in line with the sheet, and sir reported the menu_master
--   table looking "fully replaced" as a result.
--
--   A full audit of every migration 275-346 that touches menu_master
--   found the snapshot itself is internally consistent -- 275, 276, 279,
--   280, 288, 289, 332 and 345 are all correctly reflected in 274's row
--   values, so re-running 274 as it stood did not, on its own, undo any
--   of those tracked changes.
--
--   The actual gap: 'role-menu-permissions' ("Role Permission") and
--   'ownership-management' ("Ownership Management") are seeded (by 274
--   and by 345 respectively) under 'nav-administration', which is itself
--   Inactive -- so both are invisible in the sidebar. sir had them under
--   Organization; that placement was never captured in any migration, so
--   274 had nothing to preserve and kept reverting to nav-administration.
--
--   Confirmed with sir 2026-09-16: the six active root menus (Governance,
--   Oversight, Audit Management, Document Management, Organization, Audit
--   Traceability) plus Dashboard, Governance's four children (Repository
--   Subscriptions, Source Statements, Organization Practices,
--   Operationalize) and their order, and Organization's other six active
--   children (Role Master, Administration, Dependencies, Risk Acceptance
--   Approval Authority, Asset Category Assurance, Event Profile) already
--   matched exactly -- nothing there needs to change. Two things do:
--
-- THIS SCRIPT
--   1. Moves 'role-menu-permissions' and 'ownership-management' under
--      'nav-organization', at display_order 120 and 220, landing them in
--      sir's specified order: Role Master (110), Role Permission (120),
--      Administration (195), Dependencies (197), Ownership Management
--      (220), Risk Acceptance Approval Authority (260), Asset Category
--      Assurance (316), Event Profile (317).
--   2. Swaps the Oversight/Audit Management root display_order (200/300)
--      so Oversight sorts before Audit Management, per sir's listed
--      order: Governance, Oversight, Audit Management, Document
--      Management, Organization, Audit Traceability.
--
-- NO ROWS ARE DELETED, NO STATUS IS CHANGED. Only parent_menu_id and
-- display_order on four already-Active rows.
--
-- Re-runnable: yes. A second run makes no changes.
-- Rollback: database/347_menu_organization_governance_realignment_rollback.sql
-- ALSO EDIT: 274_menu_master_seed.sql -- done in this commit (see the
--            "347" note under AMENDED AFTER EXPORT there and the four
--            updated row/link values), or the next run of 274 reverts
--            this again.
-- DEPENDS ON: 022 (menu_master), 274 (nav-organization, nav-administration,
--             role-menu-permissions, nav-oversight, nav-assurance all
--             present), 345 (ownership-management present).
-- ASCII-only on purpose (sqlcmd codepage safety).
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET NOEXEC OFF;
GO

DECLARE @prereqs_ok BIT = 1;

IF SCHEMA_ID('grac_practice') IS NULL OR OBJECT_ID('grac_practice.menu_master','U') IS NULL
BEGIN PRINT 'ABORT (347): grac_practice.menu_master missing. Run 022 first.'; SET @prereqs_ok = 0; END

IF @prereqs_ok = 1 AND NOT EXISTS (SELECT 1 FROM grac_practice.menu_master WHERE menu_key = N'nav-organization')
BEGIN PRINT 'ABORT (347): nav-organization menu row missing. Run 274 first.'; SET @prereqs_ok = 0; END

IF @prereqs_ok = 1 AND NOT EXISTS (SELECT 1 FROM grac_practice.menu_master WHERE menu_key = N'role-menu-permissions')
BEGIN PRINT 'ABORT (347): role-menu-permissions menu row missing. Run 274 first.'; SET @prereqs_ok = 0; END

IF @prereqs_ok = 1 AND NOT EXISTS (SELECT 1 FROM grac_practice.menu_master WHERE menu_key = N'ownership-management')
BEGIN PRINT 'ABORT (347): ownership-management menu row missing. Run 274 or 345 first.'; SET @prereqs_ok = 0; END

IF @prereqs_ok = 1 AND NOT EXISTS (SELECT 1 FROM grac_practice.menu_master WHERE menu_key = N'nav-oversight')
BEGIN PRINT 'ABORT (347): nav-oversight menu row missing. Run 274 first.'; SET @prereqs_ok = 0; END

IF @prereqs_ok = 1 AND NOT EXISTS (SELECT 1 FROM grac_practice.menu_master WHERE menu_key = N'nav-assurance')
BEGIN PRINT 'ABORT (347): nav-assurance menu row missing. Run 274 first.'; SET @prereqs_ok = 0; END

IF @prereqs_ok = 0
BEGIN
    RAISERROR('347_menu_organization_governance_realignment: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. Role Permission and Ownership Management move under Organization.
-- =====================================================================
UPDATE m
   SET parent_menu_id = o.menu_id,
       display_order  = 120,
       updated_by     = N'seed-347',
       updated_dt     = SYSUTCDATETIME()
FROM   grac_practice.menu_master m
JOIN   grac_practice.menu_master o ON o.menu_key = N'nav-organization'
WHERE  m.menu_key = N'role-menu-permissions'
  AND  (ISNULL(m.parent_menu_id, -1) <> o.menu_id OR ISNULL(m.display_order, -1) <> 120);

PRINT '347: Role Permission moved under Organization = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

UPDATE m
   SET parent_menu_id = o.menu_id,
       display_order  = 220,
       updated_by     = N'seed-347',
       updated_dt     = SYSUTCDATETIME()
FROM   grac_practice.menu_master m
JOIN   grac_practice.menu_master o ON o.menu_key = N'nav-organization'
WHERE  m.menu_key = N'ownership-management'
  AND  (ISNULL(m.parent_menu_id, -1) <> o.menu_id OR ISNULL(m.display_order, -1) <> 220);

PRINT '347: Ownership Management moved under Organization = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

-- =====================================================================
-- 2. Oversight before Audit Management in the root order.
-- =====================================================================
UPDATE grac_practice.menu_master
   SET display_order = 200, updated_by = N'seed-347', updated_dt = SYSUTCDATETIME()
 WHERE menu_key = N'nav-oversight' AND display_order <> 200;

UPDATE grac_practice.menu_master
   SET display_order = 300, updated_by = N'seed-347', updated_dt = SYSUTCDATETIME()
 WHERE menu_key = N'nav-assurance' AND display_order <> 300;

PRINT '347: Oversight/Audit Management root order swapped.';
GO

-- =====================================================================
-- 3. Sanity report
-- =====================================================================
SELECT '347 Role Permission under Organization' AS Check_,
       CASE WHEN EXISTS (
           SELECT 1 FROM grac_practice.menu_master m
           JOIN grac_practice.menu_master o ON o.menu_id = m.parent_menu_id
           WHERE m.menu_key = N'role-menu-permissions' AND o.menu_key = N'nav-organization')
       THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT '347 Ownership Management under Organization' AS Check_,
       CASE WHEN EXISTS (
           SELECT 1 FROM grac_practice.menu_master m
           JOIN grac_practice.menu_master o ON o.menu_id = m.parent_menu_id
           WHERE m.menu_key = N'ownership-management' AND o.menu_key = N'nav-organization')
       THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT '347 Oversight before Audit Management' AS Check_,
       CASE WHEN (SELECT display_order FROM grac_practice.menu_master WHERE menu_key = N'nav-oversight')
          < (SELECT display_order FROM grac_practice.menu_master WHERE menu_key = N'nav-assurance')
       THEN 'PASS' ELSE 'FAIL' END AS Result;

SELECT 'Organization branch, active children, in display order' AS Check_,
       m.menu_name AS MenuName_, m.display_order AS Order_
FROM   grac_practice.menu_master m
JOIN   grac_practice.menu_master o ON o.menu_id = m.parent_menu_id
WHERE  o.menu_key = N'nav-organization' AND m.status = N'Active'
ORDER BY m.display_order;

SELECT 'Root menus, active, in display order' AS Check_,
       m.menu_name AS MenuName_, m.display_order AS Order_
FROM   grac_practice.menu_master m
WHERE  m.parent_menu_id IS NULL AND m.status = N'Active'
ORDER BY m.display_order;

PRINT '347 Organization branch realignment complete.';
GO
SET NOEXEC OFF;
GO
