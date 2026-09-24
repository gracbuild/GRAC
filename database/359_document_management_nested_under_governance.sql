-- =====================================================================
-- 359 "Document Management" becomes a submenu under Governance, with
-- its existing children (Document Library, Document Acknowledgements,
-- My Acknowledgements) riding along as third-level items
--
-- SIR'S INSTRUCTION
-- ------------------
-- Change the sidebar from the current 2-level shape:
--     Document Management (root)
--       -> Document Library / Document Acknowledgements / My Acknowledgements
-- to a 3-level shape:
--     Governance
--       -> Document Management
--            -> Document Library / Document Acknowledgements / My Acknowledgements
-- with every existing Document Management submenu kept, unrenamed and
-- unrestructured except "Document Uploads" -> "Document Library" (done
-- by migration 358, already live -- see below).
--
-- STARTING POINT -- TRACED BEFORE WRITING ANYTHING
-- ---------------------------------------------------
-- Migration 358 (this same effort, previous step) already renamed
-- 'document-uploads' to 'Document Library' and moved it DIRECTLY under
-- nav-governance, because at the time Sir's instruction named only that
-- one screen. Sir has now clarified the intended final shape keeps
-- Document Management itself as the mid-level parent, with Document
-- Library (and its two siblings) nested a level deeper underneath it,
-- not sitting beside Document Management's other children as a direct
-- Governance child. 358's rename stands; only document-uploads' PARENT
-- changes again here, this time to nav-documents instead of
-- nav-governance directly, and nav-documents itself moves under
-- nav-governance.
--
-- The sidebar tree (_PracticeMenuTree.cshtml) is fully recursive --
-- `@await Html.PartialAsync("_PracticeMenuTree", item.Children, ...)` --
-- with no depth limit, and 3-level nesting is already a live, shipped
-- pattern in this exact codebase: nav-assurance (Audit Management) ->
-- org-audit-definition / org-audit-configuration (mid-level containers,
-- added by 276) -> their own 8 child screens. nav-documents is the
-- simpler case of the two -- like nav-governance itself, it has
-- menu_url = NULL, so it renders as a plain collapsible folder, not
-- also a clickable page the way the Audit Definition/Configuration
-- containers are. No UI, CSS or JS change is needed for the nesting
-- itself; this migration is data-only.
--
-- WHAT THIS DOES
-- --------------
--   1. nav-documents ("Document Management"): parent_menu_id ->
--      nav-governance, display_order -> 130 (the next open slot after
--      nav-governance's current last direct child, Operationalize, at
--      120 -- the same slot 358 had given document-uploads directly,
--      now freed up and reused by its own parent folder instead).
--      module_type -> 'Governance', for the same reason 065 set
--      'resolve's module_type to 'Governance' when it was parented
--      there: cosmetic-only (the real tree renders off parent_menu_id,
--      not module_type -- see PracticeMenuService.BuildMenuItems, which
--      only falls back to module_type grouping when NO row anywhere has
--      parent_menu_id set, never true in this database), but kept in
--      step so a future reader of menu_master is not misled.
--
--   2. document-uploads ("Document Library"): parent_menu_id moves from
--      nav-governance back to nav-documents (its pre-358 parent),
--      module_type back to 'Documents' (matching its two siblings),
--      display_order back to 10 -- its original slot, and still first
--      among Document Management's children, matching Sir's example
--      listing (Document Library, then the existing submenus). The
--      rename itself (menu_name = 'Document Library') is NOT undone --
--      it is only re-asserted here defensively, the same way 065
--      re-asserts values on every row it touches.
--
--   document-acknowledgements and my-acknowledgements are not touched
--   by this migration at all -- they were already parented to
--   nav-documents by 155 and never moved by 358, so they automatically
--   travel with nav-documents to its new position under Governance
--   without any row of their own needing an UPDATE.
--
-- WHAT THIS DOES NOT DO
-- ----------------------
--   * Does not rename, remove or reorder document-acknowledgements or
--     my-acknowledgements -- same menu_key, menu_url, parent (still
--     nav-documents), module_type and display_order (20, 30) as before.
--   * Does not touch menu_key, menu_url or menu_id on any row -- every
--     existing organization_role_menu_permission grant (from 149, 152,
--     154, and nav-documents' own grant from 155) keeps working
--     untouched, since those are keyed by menu_id.
--   * Does not touch nav-governance's four existing direct children
--     (Repository Subscriptions/Source Statements/Organization
--     Practices/Operationalize) -- read here only to confirm the next
--     free display_order slot, never written.
--   * Does not touch any route, controller, API endpoint, the
--     document_upload table, or PracticeScreen.cs's Title ("Document
--     Library", set by 358) or Group (GovernanceGroup, set by 358 and
--     still correct: PracticeScreen.Group mirrors the screen's ROOT
--     ancestor, not its immediate parent -- confirmed by the identical,
--     already-shipped precedent of org-assurance-evidence-config and
--     its seven siblings, which all carry Group = AuditManagementGroup
--     despite their immediate parent being the mid-level
--     org-audit-configuration container, not nav-assurance directly).
--     No C# change accompanies this migration.
--
-- ALSO EDITED: 274_menu_master_seed.sql -- per this project's documented
-- "AMENDED AFTER EXPORT" convention (see 275/276/279/280/332/347/358):
-- 274 is a MERGE-with-UPDATE snapshot that re-asserts the WHOLE tree on
-- every run, including a hardcoded 30-row "these are the roots" list
-- that re-NULLs parent_menu_id. 'nav-documents' was in that list (it
-- WAS a root); it has been removed from it and added to the parent-link
-- list instead, or the next run of 274 would silently pull Document
-- Management back out from under Governance. 'document-uploads' row/link
-- updated back to nav-documents/'Documents'/10 to match. See 274's new
-- "359" bullet for the full note.
--
-- DEPENDS ON: 358 (document-uploads renamed to Document Library; both
-- nav-documents and nav-governance already present).
-- Rollback: 359_document_management_nested_under_governance_rollback.sql
-- Re-runnable: yes. A second run makes no changes.
-- ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET NOEXEC OFF;
GO

DECLARE @prereqs_ok BIT = 1;

IF SCHEMA_ID('grac_practice') IS NULL OR OBJECT_ID('grac_practice.menu_master','U') IS NULL
BEGIN PRINT 'ABORT (359): grac_practice.menu_master missing.'; SET @prereqs_ok = 0; END

IF @prereqs_ok = 1 AND NOT EXISTS (SELECT 1 FROM grac_practice.menu_master WHERE menu_key = N'nav-documents')
BEGIN PRINT 'ABORT (359): nav-documents menu row missing. Run 155 first.'; SET @prereqs_ok = 0; END

IF @prereqs_ok = 1 AND NOT EXISTS (SELECT 1 FROM grac_practice.menu_master WHERE menu_key = N'document-uploads')
BEGIN PRINT 'ABORT (359): document-uploads menu row missing. Run 149 first.'; SET @prereqs_ok = 0; END

IF @prereqs_ok = 1 AND NOT EXISTS (SELECT 1 FROM grac_practice.menu_master WHERE menu_key = N'nav-governance')
BEGIN PRINT 'ABORT (359): nav-governance parent row missing. Run 052 first.'; SET @prereqs_ok = 0; END

IF @prereqs_ok = 0
BEGIN
    RAISERROR('359_document_management_nested_under_governance: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. nav-documents ("Document Management") moves under nav-governance.
-- =====================================================================
DECLARE @gov_parent_id BIGINT = (SELECT menu_id FROM grac_practice.menu_master WHERE menu_key = N'nav-governance');

UPDATE grac_practice.menu_master
   SET parent_menu_id = @gov_parent_id,
       module_type    = N'Governance',
       display_order  = 130,
       status         = N'Active',
       updated_by     = 'seed-359',
       updated_dt     = SYSUTCDATETIME()
 WHERE menu_key = N'nav-documents';

PRINT '359: Document Management moved under Governance = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

-- =====================================================================
-- 2. document-uploads ("Document Library") moves back under
--    nav-documents, restoring its pre-358 parent/order while keeping
--    358's rename.
-- =====================================================================
DECLARE @docs_parent_id BIGINT = (SELECT menu_id FROM grac_practice.menu_master WHERE menu_key = N'nav-documents');

UPDATE grac_practice.menu_master
   SET menu_name      = N'Document Library',
       parent_menu_id = @docs_parent_id,
       module_type    = N'Documents',
       display_order  = 10,
       status         = N'Active',
       updated_by     = 'seed-359',
       updated_dt     = SYSUTCDATETIME()
 WHERE menu_key = N'document-uploads';

PRINT '359: Document Library re-nested under Document Management = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

-- =====================================================================
-- Verification
-- =====================================================================
SELECT '359-a Document Management is a child of Governance' AS Check_,
       CASE WHEN EXISTS (
                SELECT 1 FROM grac_practice.menu_master m
                JOIN grac_practice.menu_master p ON p.menu_id = m.parent_menu_id
                WHERE m.menu_key = N'nav-documents' AND p.menu_key = N'nav-governance')
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '359-b Document Library is a grandchild of Governance, via Document Management',
       CASE WHEN EXISTS (
                SELECT 1
                  FROM grac_practice.menu_master u
                  JOIN grac_practice.menu_master d ON d.menu_id = u.parent_menu_id
                  JOIN grac_practice.menu_master g ON g.menu_id = d.parent_menu_id
                 WHERE u.menu_key = N'document-uploads'
                   AND d.menu_key = N'nav-documents'
                   AND g.menu_key = N'nav-governance')
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '359-c document-uploads menu_name is still Document Library',
       CASE WHEN (SELECT menu_name FROM grac_practice.menu_master WHERE menu_key = N'document-uploads') = N'Document Library'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '359-d document-acknowledgements / my-acknowledgements untouched (still under Document Management)',
       CASE WHEN (
                SELECT COUNT(*)
                  FROM grac_practice.menu_master m
                  JOIN grac_practice.menu_master p ON p.menu_id = m.parent_menu_id
                 WHERE p.menu_key = N'nav-documents'
                   AND m.menu_key IN (N'document-acknowledgements', N'my-acknowledgements')
            ) = 2
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '359-e existing menu permissions preserved (same menu_ids throughout)',
       CASE WHEN EXISTS (
                SELECT 1
                  FROM grac_practice.organization_role_menu_permission p
                  JOIN grac_practice.menu_master m ON m.menu_id = p.menu_id
                 WHERE m.menu_key IN (N'document-uploads', N'nav-documents') AND p.can_view = 1)
            THEN 'PASS' ELSE 'FAIL' END;

-- Diagnostic -- the full 3-level branch, so the shape can be eyeballed.
PRINT '--- Diagnostic: Governance branch, 3 levels ---';
SELECT g.menu_name AS Level1, d.menu_name AS Level2, u.menu_name AS Level3,
       u.display_order AS Level3Order, u.status AS Level3Status
  FROM grac_practice.menu_master g
  LEFT JOIN grac_practice.menu_master d ON d.parent_menu_id = g.menu_id
  LEFT JOIN grac_practice.menu_master u ON u.parent_menu_id = d.menu_id
 WHERE g.menu_key = N'nav-governance'
 ORDER BY d.display_order, u.display_order;

PRINT '359 complete. Document Management now sits under Governance, and';
PRINT '    Document Library / Document Acknowledgements / My Acknowledgements';
PRINT '    are its third-level children, Document Library listed first.';
PRINT '    No menu_key, menu_url, menu_id or permission grant changed.';
GO
SET NOEXEC OFF;
GO
