-- =====================================================================
-- 334 ROLLBACK -- Operationalize, evidence details before adoption
--
-- 334 is a verification script. It creates, alters and drops nothing,
-- so there is nothing here to undo.
--
-- To roll the CHANGE back, revert the screen:
--
--     src/PracticeManagement.Web/Views/Practice/Partials/
--         resolve-workspace.cshtml
--
-- The reverted screen talks to exactly the same procedures with exactly
-- the same payloads -- sp_resolve_obligation_adopt, sp_resolve_evidence_list
-- and sp_resolve_evidence_save are untouched by 334 -- so no database
-- step is needed in either direction, and evidence already filled in
-- through the new path stays where it is.
--
-- SAFE TO RE-RUN. Does nothing.
-- ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
GO

PRINT '334 rollback: nothing to undo -- 334 makes no database change. Revert resolve-workspace.cshtml instead.';
GO
