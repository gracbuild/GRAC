-- =====================================================================
-- 373 "Risk Centre" renamed to "Risk Management" and promoted to a
-- top-level (root) menu, out from under "Oversight"
--
-- SIR'S INSTRUCTION
-- ------------------
--   1. Find the existing Risk Centre menu item (the one sitting under
--      the "Oversight" parent menu -- confirmed with sir; there is no
--      row literally named "Risk Center Oversight", and the other two
--      Risk-named rows -- risk-intelligence (Inactive, under Assurance
--      Management) and risk-acceptance-authority (under Organization) --
--      are not it).
--   2. Change its Parent Menu ID to NULL so it becomes a top-level/root
--      menu instead of a child of "Oversight".
--   3. Rename it from "Risk Centre" to "Risk Management".
--   4. Menu configuration change only. Preserve menu_id, route,
--      permissions, ordering and functionality unless a change is
--      strictly required for the new parent relationship. Do not touch
--      any other Risk menu or module.
--
-- WHAT THIS DOES
-- --------------
--   menu_master.risk-centre: menu_name -> 'Risk Management',
--   parent_menu_id -> NULL, module_type -> 'Risk Management'.
--   menu_key, menu_url, menu_id, display_order (280) and status
--   ('Active') are UNCHANGED.
--
--   module_type is the one field touched beyond what sir listed, and it
--   IS "strictly required for the new parent relationship": every other
--   root-level menu in this tree carries its own name as module_type
--   (nav-oversight/'Oversight', nav-governance/'Governance',
--   nav-organization/'Organization', nav-administration/'Administration',
--   nav-operations/'Operations', nav-registers/'Registers', nav-assurance/
--   'Audit Management', nav-workflow/'Workflow' -- all confirmed in
--   274_menu_master_seed.sql). module_type's only runtime consumer,
--   confirmed by grep, is the Organization Role Management screen's
--   permission-matrix section header (practice.js
--   renderRolePermissionMatrix -- "const group = ... ModuleType ...").
--   Leaving it as 'Oversight' would show this now-root-level menu
--   grouped under an "Oversight" heading in that screen despite no
--   longer being part of Oversight anywhere else in the app --
--   inconsistent with the new parent relationship, not a functional
--   change (permission ROWS stay exactly as they are, see below).
--
-- WHAT THIS DOES NOT DO
-- ----------------------
--   * Does not touch menu_key, menu_url, menu_id or display_order --
--     Practice/Index/risk-centre still resolves to the same screen,
--     same partial, same JS, same API endpoints, and it sorts at
--     display_order 280 among the (now sibling) root items exactly as
--     it sorted at 280 among Oversight's children before -- between
--     "Oversight" (200) and "Operations" / "Audit Management" (300).
--     Sir asked to preserve ordering; nothing about becoming root
--     requires changing it, so it is left as-is.
--   * Does not touch organization_role_menu_permission rows -- they are
--     keyed by menu_id, which is unchanged, so every existing grant
--     (can_view/add/edit/delete/approve, from 171) keeps working with
--     zero touch. Verified below.
--   * Does not touch any other Risk-named menu (risk-intelligence,
--     risk-acceptance-authority) or any other child of nav-oversight
--     (assurance-calendar, tasks, gaps, exception-centre,
--     my-notifications all stay exactly where they are).
--   * Does not touch nav-oversight itself -- it keeps its other five
--     children and stays a top-level group; it is not emptied out by
--     this change.
--   * Does not touch feature_flag_master.screen.risk-centre -- unlike
--     358's Document Library rename, that flag's display name
--     ("Risk Centre") is not part of sir's instruction here and this is
--     scoped to "menu configuration" per sir's own "Important" note;
--     left as-is.
--   * Does not touch PracticeManagement.Web/Models/PracticeScreen.cs.
--     Its "risk-centre" row's Title ("Risk Centre") and Group
--     (OversightGroup) drive the risk-centre PAGE's own heading/eyebrow
--     via PracticeController.ShowArea, which reads PracticeScreen.All
--     directly and does not consult menu_master (confirmed the same way
--     358's header comment confirmed it for document-uploads) -- so the
--     SIDEBAR label (this migration) and the PAGE heading are two
--     independent things. Sir's instruction here was explicitly "menu
--     configuration change only," unlike 358 which named "menu items,
--     page headings, breadcrumbs, labels" -- so the page heading is
--     left reading "Oversight / Risk Centre" on purpose. Flagged in the
--     delivery explanation in case sir wants that half updated too.
--
-- ALSO EDITED: 274_menu_master_seed.sql -- per this project's own
-- documented convention (see its "AMENDED AFTER EXPORT" header section,
-- and precedent in 275/276/279/280/332/347/358/359): 274 is a
-- MERGE-with-UPDATE snapshot that re-asserts the FULL menu tree on every
-- run, so leaving its 'risk-centre' row/link at the old name and parent
-- would silently undo this migration the next time 274 is re-run.
-- Updated in the same commit: the Section 1 VALUES row (name + module_type),
-- the Section 2 parent-link list (risk-centre -> nav-oversight pair
-- removed), and the Section 2 root list (risk-centre added) -- exactly
-- the shape 359 used to promote nav-documents the other direction. See
-- the new bullet under 274's "AMENDED AFTER EXPORT" section.
--
-- DEPENDS ON: 022 (menu_master), 171 (risk-centre menu row), 052/274
-- (nav-oversight).
-- Rollback: 373_risk_centre_menu_becomes_risk_management_root_rollback.sql
-- Re-runnable: yes. A second run makes no changes.
-- ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET NOEXEC OFF;
GO

DECLARE @prereqs_ok BIT = 1;

IF SCHEMA_ID('grac_practice') IS NULL OR OBJECT_ID('grac_practice.menu_master','U') IS NULL
BEGIN PRINT 'ABORT (373): grac_practice.menu_master missing.'; SET @prereqs_ok = 0; END

IF @prereqs_ok = 1 AND NOT EXISTS (SELECT 1 FROM grac_practice.menu_master WHERE menu_key = N'risk-centre')
BEGIN PRINT 'ABORT (373): risk-centre menu row missing. Run 171 first.'; SET @prereqs_ok = 0; END

IF @prereqs_ok = 0
BEGIN
    RAISERROR('373_risk_centre_menu_becomes_risk_management_root: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. Rename + promote to root. display_order (280), status (Active),
--    menu_key and menu_url are untouched -- see header.
-- =====================================================================
UPDATE grac_practice.menu_master
   SET menu_name      = N'Risk Management',
       parent_menu_id = NULL,
       module_type    = N'Risk Management',
       updated_by     = 'seed-373',
       updated_dt     = SYSUTCDATETIME()
 WHERE menu_key = N'risk-centre';

PRINT '373: risk-centre renamed to Risk Management and promoted to root = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

-- =====================================================================
-- Verification
-- =====================================================================
SELECT '373-a menu_name is Risk Management' AS Check_,
       CASE WHEN (SELECT menu_name FROM grac_practice.menu_master WHERE menu_key = N'risk-centre') = N'Risk Management'
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '373-b parent_menu_id is NULL (root)',
       CASE WHEN (SELECT parent_menu_id FROM grac_practice.menu_master WHERE menu_key = N'risk-centre') IS NULL
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '373-c module_type is Risk Management',
       CASE WHEN (SELECT module_type FROM grac_practice.menu_master WHERE menu_key = N'risk-centre') = N'Risk Management'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '373-d row still Active, same key/url/order (menu_id untouched)',
       CASE WHEN EXISTS (
                SELECT 1 FROM grac_practice.menu_master
                WHERE menu_key = N'risk-centre' AND status = N'Active'
                  AND menu_url = N'Practice/Index/risk-centre'
                  AND display_order = 280)
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '373-e existing menu permissions preserved (same menu_id)',
       CASE WHEN EXISTS (
                SELECT 1
                  FROM grac_practice.organization_role_menu_permission p
                  JOIN grac_practice.menu_master m ON m.menu_id = p.menu_id
                 WHERE m.menu_key = N'risk-centre' AND p.can_view = 1)
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '373-f nav-oversight still has its other children',
       CASE WHEN (
                SELECT COUNT(*) FROM grac_practice.menu_master c
                  JOIN grac_practice.menu_master p ON p.menu_id = c.parent_menu_id
                 WHERE p.menu_key = N'nav-oversight') >= 5
            THEN 'PASS' ELSE 'FAIL' END;

-- Diagnostic -- every root-level menu, in display order, so Risk
-- Management's new position among its new siblings can be eyeballed.
PRINT '--- Diagnostic: root-level (top-level) menus, in display order ---';
SELECT display_order AS Ord, menu_key AS Key_, menu_name AS Name_, module_type AS ModuleType_, status AS Status_
  FROM grac_practice.menu_master
 WHERE parent_menu_id IS NULL
 ORDER BY display_order;

-- Diagnostic -- nav-oversight's remaining children, to confirm none of
-- them moved by accident.
PRINT '--- Diagnostic: nav-oversight remaining children, in display order ---';
SELECT c.display_order AS Ord, c.menu_key AS Key_, c.menu_name AS Name_, c.status AS Status_
  FROM grac_practice.menu_master c
  JOIN grac_practice.menu_master p ON p.menu_id = c.parent_menu_id
 WHERE p.menu_key = N'nav-oversight'
 ORDER BY c.display_order;

PRINT '373 complete. Risk Centre (menu_key risk-centre, unchanged) now';
PRINT '    reads "Risk Management" and sits as a top-level menu, no';
PRINT '    longer under Oversight. menu_id, menu_url, display_order,';
PRINT '    status and every existing permission grant are unchanged --';
PRINT '    only its label, parent and module_type moved.';
GO
SET NOEXEC OFF;
GO
