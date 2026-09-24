-- =====================================================================
-- 358 "Document Uploads" renamed to "Document Library" and moved under
-- Governance as a submenu
--
-- SIR'S INSTRUCTION
-- ------------------
--   1. Rename "Document Uploads" to "Document Library" wherever it is
--      displayed in the UI, including menu items, page headings,
--      breadcrumbs, labels, and related navigation text.
--   2. Move "Document Library" under the "Governance" menu as a
--      submenu.
--   3. Do not change any existing functionality, routes, API logic,
--      database structure, permissions, or data flow unless required
--      only for the menu/navigation change.
--   4. Follow the existing project architecture, UI style, naming
--      conventions, and implementation patterns.
--
-- WHERE THIS LIVES
-- -----------------
-- Traced end to end before writing anything:
--
--   * The SIDEBAR label and its parent grouping are entirely DB-driven.
--     PracticeMenuService builds the tree straight from
--     grac_practice.menu_master (menu_name, parent_menu_id, module_type,
--     display_order) -- see 149/155's own header comments: "Since
--     migration 052 the sidebar renders via parent_menu_id, not
--     module_type." This migration is the DB half of the change.
--
--   * The PAGE ITSELF (heading, browser-tab title, and the in-page
--     "Group / Title" eyebrow on Views/Practice/Manage.cshtml) does NOT
--     read menu_master at all -- PracticeController.ShowArea resolves
--     the screen straight from the static PracticeScreen.All array by
--     Key, independent of the sidebar. That half of the rename (Title
--     "Document Uploads" -> "Document Library" and Group OversightGroup
--     -> GovernanceGroup, so the eyebrow reads "Governance / Document
--     Library" and matches the new sidebar placement) is a C# change,
--     delivered alongside this migration in
--     PracticeManagement.Web/Models/PracticeScreen.cs -- not something a
--     SQL migration can reach, called out here so the two halves aren't
--     mistaken for redundant.
--
--   * document-uploads.cshtml / document-uploads.js only ever say
--     "Document Uploads" inside a comment, never in rendered markup or a
--     user-visible string -- confirmed by grep. Nothing to change there.
--
-- WHAT THIS DOES
-- --------------
--   1. menu_master.document-uploads: menu_name -> 'Document Library',
--      re-parented from nav-documents to nav-governance, module_type ->
--      'Governance', display_order -> 130 (the next open slot after
--      nav-governance's current last child, Operationalize/'resolve' at
--      120 -- see 065/347, both re-confirmed live before this migration
--      was written). menu_key, menu_url and menu_id are UNCHANGED, so
--      every existing organization_role_menu_permission grant on this
--      menu (from 149) keeps working with zero touch -- permission rows
--      are keyed by menu_id, not by name or parent.
--
--   2. feature_flag_master.feature_name for 'screen.document-uploads'
--      also becomes 'Document Library'. This flag is never rendered to
--      an end user (grep-confirmed -- Manage.cshtml only references
--      feature_flag_master in a comment) so it is not part of "the UI"
--      Sir asked about; it is updated purely so the feature's own
--      display name does not go stale next to its menu label.
--      feature_code (the actual lookup key the partial's render-gate
--      checks) is UNCHANGED, so the Phase-1 partial keeps rendering
--      exactly as before for every org where 149 turned it on.
--
-- WHAT THIS DOES NOT DO
-- ----------------------
--   * Does not touch document-acknowledgements or my-acknowledgements --
--     Sir named "Document Uploads" specifically; those two stay exactly
--     where 155 put them, under nav-documents ("Document Management").
--   * Does not touch nav-documents itself -- it keeps its other two
--     children and stays a top-level group.
--   * Does not rename or move menu_key, menu_url, the document_upload
--     table, DocumentUploadController (API or Web), or any route --
--     Practice/Index/document-uploads still resolves to the same
--     screen, same partial, same JS, same API endpoints.
--   * Does not touch organization_role_menu_permission rows -- same
--     menu_id, so every existing grant (Admin can_view/add/edit/delete/
--     approve from 149) is untouched and unaffected.
--   * Does not touch nav-governance's four existing children
--     (Repository Subscriptions/Source Statements/Organization
--     Practices/Operationalize) -- their keys, parents and display_order
--     are read here only to compute the next slot, never written.
--
-- ALSO EDITED: 274_menu_master_seed.sql -- per this project's own
-- documented convention (see its "AMENDED AFTER EXPORT" header section,
-- and precedent in 275/276/279/280/332/347): 274 is a MERGE-with-UPDATE
-- snapshot that re-asserts the FULL menu tree on every run, so leaving
-- its 'document-uploads' row/link at the old name and parent would
-- silently undo this migration the next time 274 is re-run. Updated in
-- the same commit -- see the new bullet under 274's "AMENDED AFTER
-- EXPORT" section and its two changed lines (VALUES row + parent link).
--
-- DEPENDS ON: 022 (menu_master), 149 (document-uploads menu row), 155
-- (nav-documents; superseded here for this one child only), 052/065/347
-- (nav-governance and its current 4 children).
-- Rollback: 358_document_uploads_rename_to_document_library_and_move_to_governance_rollback.sql
-- Re-runnable: yes. A second run makes no changes.
-- ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET NOEXEC OFF;
GO

DECLARE @prereqs_ok BIT = 1;

IF SCHEMA_ID('grac_practice') IS NULL OR OBJECT_ID('grac_practice.menu_master','U') IS NULL
BEGIN PRINT 'ABORT (358): grac_practice.menu_master missing.'; SET @prereqs_ok = 0; END

IF @prereqs_ok = 1 AND NOT EXISTS (SELECT 1 FROM grac_practice.menu_master WHERE menu_key = N'document-uploads')
BEGIN PRINT 'ABORT (358): document-uploads menu row missing. Run 149 first.'; SET @prereqs_ok = 0; END

IF @prereqs_ok = 1 AND NOT EXISTS (SELECT 1 FROM grac_practice.menu_master WHERE menu_key = N'nav-governance')
BEGIN PRINT 'ABORT (358): nav-governance parent row missing. Run 052 first.'; SET @prereqs_ok = 0; END

IF @prereqs_ok = 0
BEGIN
    RAISERROR('358_document_uploads_rename_to_document_library_and_move_to_governance: prerequisites missing.', 16, 1);
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. Rename + re-parent the menu row.
--    display_order 130 -- next free slot after nav-governance's current
--    last child (Operationalize / 'resolve', at 120).
-- =====================================================================
DECLARE @gov_parent_id BIGINT = (SELECT menu_id FROM grac_practice.menu_master WHERE menu_key = N'nav-governance');

UPDATE grac_practice.menu_master
   SET menu_name      = N'Document Library',
       parent_menu_id = @gov_parent_id,
       module_type    = N'Governance',
       display_order  = 130,
       status         = N'Active',
       updated_by     = 'seed-358',
       updated_dt     = SYSUTCDATETIME()
 WHERE menu_key = N'document-uploads';

PRINT '358: document-uploads renamed to Document Library and moved under Governance = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

-- =====================================================================
-- 2. feature_flag_master display name -- cosmetic only, not user-facing
--    (see header). feature_code, default_enabled and every per-org
--    feature_flag row are untouched.
-- =====================================================================
UPDATE grac_practice.feature_flag_master
   SET feature_name = N'Document Library',
       updated_by   = 'seed-358',
       updated_dt   = SYSUTCDATETIME()
 WHERE feature_code = N'screen.document-uploads';

PRINT '358: feature_flag_master.document-uploads display name updated = ' + CAST(@@ROWCOUNT AS NVARCHAR(20));
GO

-- =====================================================================
-- Verification
-- =====================================================================
SELECT '358-a menu_name is Document Library' AS Check_,
       CASE WHEN (SELECT menu_name FROM grac_practice.menu_master WHERE menu_key = N'document-uploads') = N'Document Library'
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT '358-b parent is nav-governance',
       CASE WHEN EXISTS (
                SELECT 1 FROM grac_practice.menu_master m
                JOIN grac_practice.menu_master p ON p.menu_id = m.parent_menu_id
                WHERE m.menu_key = N'document-uploads' AND p.menu_key = N'nav-governance')
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '358-c module_type is Governance',
       CASE WHEN (SELECT module_type FROM grac_practice.menu_master WHERE menu_key = N'document-uploads') = N'Governance'
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '358-d row still Active (menu_id/menu_key/menu_url untouched)',
       CASE WHEN EXISTS (
                SELECT 1 FROM grac_practice.menu_master
                WHERE menu_key = N'document-uploads' AND status = N'Active'
                  AND menu_url = N'Practice/Index/document-uploads')
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT '358-e existing menu permissions preserved (same menu_id)',
       CASE WHEN EXISTS (
                SELECT 1
                  FROM grac_practice.organization_role_menu_permission p
                  JOIN grac_practice.menu_master m ON m.menu_id = p.menu_id
                 WHERE m.menu_key = N'document-uploads' AND p.can_view = 1)
            THEN 'PASS' ELSE 'FAIL' END;

-- Diagnostic -- Governance's full child list in order, so the new
-- position of Document Library can be eyeballed against its siblings.
PRINT '--- Diagnostic: nav-governance children, in display order ---';
SELECT c.display_order AS Ord, c.menu_key AS Key_, c.menu_name AS Name_, c.status AS Status_
  FROM grac_practice.menu_master c
  JOIN grac_practice.menu_master p ON p.menu_id = c.parent_menu_id
 WHERE p.menu_key = N'nav-governance'
 ORDER BY c.display_order;

PRINT '358 complete. Document Library (formerly Document Uploads) now';
PRINT '    sits under Governance in the sidebar. menu_key, menu_url,';
PRINT '    menu_id and every existing permission grant are unchanged --';
PRINT '    only its label, parent, group and sort position moved.';
PRINT '    Remember: PracticeScreen.cs also needs its own Title/Group';
PRINT '    update (delivered alongside this file) for the page heading';
PRINT '    and eyebrow to match -- this migration is the sidebar half.';
GO
SET NOEXEC OFF;
GO
