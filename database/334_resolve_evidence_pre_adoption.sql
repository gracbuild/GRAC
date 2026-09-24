-- =====================================================================
-- 334 Operationalize -- evidence details before adoption
--
-- ---------------------------------------------------------------------
-- WHAT CHANGED, AND WHERE
-- ---------------------------------------------------------------------
-- This change is in the SCREEN, not in the database:
--
--     src/PracticeManagement.Web/Views/Practice/Partials/
--         resolve-workspace.cshtml
--
-- Expanding an obligation on Operationalize showed its evidence as a
-- read-only list -- type name, a "Not started" badge, the published
-- remark -- with no inputs. The inputs appeared only after the
-- obligation had been saved once, because that save is what creates the
-- practice_instance_evidence rows the inputs are bound to. So filling
-- evidence in took two saves and a reload for one decision.
--
-- The screen now renders the same four inputs (Evidence name, Location,
-- Locator, Description) on that pre-adoption list, holds what is typed
-- in a client-side draft, and the card's existing "Save obligation"
-- button:
--
--     1. POSTs the obligation       -> sp_resolve_obligation_adopt
--                                      (which adopts it, and creates its
--                                       evidence rows -- see below)
--     2. re-reads the evidence list -> sp_resolve_evidence_list
--     3. POSTs each draft           -> sp_resolve_evidence_save
--
-- One click, obligation and evidence together.
--
-- ---------------------------------------------------------------------
-- NO SCHEMA CHANGE. NO PROCEDURE CHANGE. NO DATA CHANGE.
-- ---------------------------------------------------------------------
-- Nothing here creates, alters or drops anything. This file exists for
-- two reasons, and it is the reason the .cshtml comments can say
-- "migration 334" and point at something real:
--
--   1. It records WHY the screen changed, in the place this codebase
--      keeps that record.
--   2. It VERIFIES the three database facts the new screen depends on,
--      so a deployment that is behind on scripts fails loudly here
--      rather than quietly on the screen.
--
-- Run it after 304. It prints PASS or FAIL per check and changes
-- nothing either way.
--
-- ---------------------------------------------------------------------
-- THE THREE FACTS THE SCREEN DEPENDS ON
-- ---------------------------------------------------------------------
-- (1) ADOPT CREATES THE EVIDENCE ROWS, SYNCHRONOUSLY.
--     The draft is posted straight after the obligation POST returns,
--     so the rows must exist by then. They do: migration 304 moved the
--     evidence block out of sp_resolve_obligation_adopt into
--     sp_resolve_evidence_reconcile_for_instance and left an EXEC of it
--     in place, INSIDE adopt's transaction and before its COMMIT.
--     Against a pre-304 database the inline block does the same work in
--     the same call, so the screen still behaves -- but check 1 below
--     names which of the two is installed.
--
-- (2) ONE EVIDENCE ROW PER (OBLIGATION, EVIDENCE TYPE).
--     This is what lets a draft find its row. The reconcile inserts
--
--         GROUP BY r.ObligationId, pet.evidence_type_id
--
--     so two published evidence rows of the same type collapse into one
--     practice row. The screen's preview is now keyed the same way --
--     by evidence type, merging the published remarks -- where it used
--     to key on ObligationEvidenceId and could therefore list two boxes
--     where adoption would create one row.
--
--     That also puts the preview back in step with the count beside it:
--     sp_resolve_obligation_list computes PublishedEvidenceCount as
--     COUNT(DISTINCT roe.evidence_type_id) (see 302's note), so the
--     header already counted each type once while the list below it did
--     not. Same rule in both places now.
--
-- (3) THE SAVE ENDPOINT IS INSTANCE-SCOPED.
--     sp_resolve_evidence_save resolves the row by evidence_id AND
--     practice_instance_id and THROWs 52642 otherwise, so an evidence id
--     the client resolved for one instance cannot be written against
--     another. The new path resolves ids from sp_resolve_evidence_list
--     for the open instance, which is inside that guard.
--
-- ---------------------------------------------------------------------
-- WHAT IS NOT DONE HERE, AND WHY
-- ---------------------------------------------------------------------
-- sp_resolve_evidence_list does not project source_obligation_evidence_id
-- even though the column exists and the reconcile writes it. Adding it
-- would give the client an id-based match instead of the evidence-type
-- match described in (2). It is deliberately left alone: the type match
-- is not an approximation but the exact rule the insert uses, the two
-- type names are identical by construction (the insert joins
-- grac_practice.evidence_type_master to GRAC_New.evidence_type_master ON
-- evidence_type_name), and rows created before 144/231 carry NULL in
-- that column and would need the type fallback anyway. A second match
-- key that can only ever agree with the first is not worth the column.
--
-- SAFE TO RE-RUN. Read-only.
-- Rollback: 334_resolve_evidence_pre_adoption_rollback.sql (also a no-op)
-- ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

PRINT '--- 334: verifying database support for pre-adoption evidence ---';
GO

-- ---------------------------------------------------------------------
-- Check 1: adopt creates evidence rows in the same call.
-- ---------------------------------------------------------------------
IF OBJECT_ID('grac_practice.sp_resolve_obligation_adopt','P') IS NULL
    PRINT 'FAIL (334.1): sp_resolve_obligation_adopt is missing -- run 244, then 304.';
ELSE IF OBJECT_ID('grac_practice.sp_resolve_evidence_reconcile_for_instance','P') IS NOT NULL
    PRINT 'PASS (334.1): adopt delegates evidence creation to sp_resolve_evidence_reconcile_for_instance (304 installed).';
ELSE IF EXISTS (
        SELECT 1 FROM sys.sql_modules m
        WHERE  m.object_id = OBJECT_ID('grac_practice.sp_resolve_obligation_adopt')
          AND  m.definition LIKE N'%practice_instance_evidence%')
    PRINT 'PASS (334.1): adopt creates evidence inline (pre-304). Supported, but 304 is recommended.';
ELSE
    PRINT 'FAIL (334.1): sp_resolve_obligation_adopt neither creates evidence nor calls the reconcile. Run 244 and 304.';
GO

-- ---------------------------------------------------------------------
-- Check 2: one evidence row per (obligation, evidence type).
--
-- Asserted against live data rather than procedure text: the rule only
-- matters because the screen relies on the result, and the result is
-- what can be measured. Repository-sourced rows only -- obligation_id
-- must be > 0, because an organisation-defined obligation's evidence is
-- matched on source_practice_instance_obligation_id (231/232) and is not
-- created by the reconcile at all.
-- ---------------------------------------------------------------------
IF OBJECT_ID('grac_practice.practice_instance_evidence','U') IS NULL
    PRINT 'FAIL (334.2): practice_instance_evidence is missing -- run 140 first.';
ELSE
BEGIN
    DECLARE @dupes INT;

    SELECT @dupes = COUNT(1)
    FROM (
        SELECT e.practice_instance_id, e.source_obligation_id, e.evidence_type_id
        FROM   grac_practice.practice_instance_evidence e
        WHERE  e.status = N'Active'
          AND  e.source_obligation_id > 0
        GROUP  BY e.practice_instance_id, e.source_obligation_id, e.evidence_type_id
        HAVING COUNT(1) > 1
    ) d;

    IF @dupes = 0
        PRINT 'PASS (334.2): one active evidence row per instance/obligation/type.';
    ELSE
        PRINT 'WARN (334.2): ' + CAST(@dupes AS VARCHAR(20))
            + ' instance/obligation/type combination(s) carry more than one active evidence row. '
            + 'The screen will fill the first of each; run _diag_evidence_migration_state.sql to see them.';
END
GO

-- ---------------------------------------------------------------------
-- Check 3: the save endpoint exists and is instance-scoped.
-- ---------------------------------------------------------------------
IF OBJECT_ID('grac_practice.sp_resolve_evidence_save','P') IS NULL
    PRINT 'FAIL (334.3): sp_resolve_evidence_save is missing -- run 143, then 254.';
ELSE IF NOT EXISTS (
        SELECT 1 FROM sys.parameters p
        WHERE  p.object_id = OBJECT_ID('grac_practice.sp_resolve_evidence_save')
          AND  p.name = '@evidence_name')
    PRINT 'FAIL (334.3): sp_resolve_evidence_save has no @evidence_name -- run 254. The screen posts it.';
ELSE IF EXISTS (
        SELECT 1 FROM sys.sql_modules m
        WHERE  m.object_id = OBJECT_ID('grac_practice.sp_resolve_evidence_save')
          AND  m.definition LIKE N'%practice_instance_id = @practice_instance_id%')
    PRINT 'PASS (334.3): sp_resolve_evidence_save accepts @evidence_name and is scoped to the instance.';
ELSE
    PRINT 'WARN (334.3): sp_resolve_evidence_save does not appear to scope by practice instance. Re-run 254.';
GO

-- ---------------------------------------------------------------------
-- Check 4: the list the screen matches against.
-- ---------------------------------------------------------------------
IF OBJECT_ID('grac_practice.sp_resolve_evidence_list','P') IS NULL
    PRINT 'FAIL (334.4): sp_resolve_evidence_list is missing -- run 143, then 254 and 306.';
ELSE IF EXISTS (
        SELECT 1 FROM sys.sql_modules m
        WHERE  m.object_id = OBJECT_ID('grac_practice.sp_resolve_evidence_list')
          AND  m.definition LIKE N'%EvidenceType%'
          AND  m.definition LIKE N'%SourceObligationId%')
    PRINT 'PASS (334.4): sp_resolve_evidence_list returns SourceObligationId and EvidenceType -- the two columns the draft matches on.';
ELSE
    PRINT 'FAIL (334.4): sp_resolve_evidence_list does not return SourceObligationId and EvidenceType. Re-run 254 and 306.';
GO

PRINT '--- 334: done. Nothing was changed. ---';
GO
