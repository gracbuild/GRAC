-- =====================================================================
-- 230 Trigger mode and event type vocabulary -- ROLLBACK
--
-- Drops grac_practice.sp_resolve_obligation_vocabulary.
--
-- 230 adds one read-only procedure and writes nothing, so there is
-- nothing else to undo.
--
-- WHAT THE FORM DOES AFTERWARDS
-- -----------------------------
-- The vocabulary fetch returns non-OK, the trigger mode and event lists
-- stay empty, and the Assurance panel falls back to the inferred rules
-- from migrations 228/229 -- which is what it used before 230 existed.
-- The mirrored labels and field order survive; only the two dropdowns
-- lose their options, and the trigger mode degrades to a text box.
--
-- REVERT THE WEB TIER TOO if the fallback is not wanted -- but it is
-- safe either way, which is the point of keeping 228/229 in place rather
-- than deleting them when 230 landed.
--
-- ASCII-only on purpose (see the forward script header).
-- Idempotent: safe to re-run.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF SCHEMA_ID('grac_practice') IS NULL
BEGIN
    PRINT 'ABORT (230 rollback): schema grac_practice missing.';
    SET NOEXEC ON;
END
GO

IF OBJECT_ID('grac_practice.sp_resolve_obligation_vocabulary','P') IS NOT NULL
BEGIN
    DROP PROCEDURE grac_practice.sp_resolve_obligation_vocabulary;
    PRINT '230 rollback: sp_resolve_obligation_vocabulary dropped.';
END
ELSE
    PRINT '230 rollback: sp_resolve_obligation_vocabulary already absent.';
GO

PRINT '=== 230 rollback verification ===';

SELECT 'vocabulary procedure removed' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.sp_resolve_obligation_vocabulary','P') IS NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT 'inferred rules still available (the fallback)',
       CASE WHEN OBJECT_ID('grac_practice.sp_resolve_obligation_type_field_rules','P') IS NOT NULL
            THEN 'PASS' ELSE 'REVIEW -- 228/229 also rolled back; the panel shows every field' END;

PRINT '';
PRINT '230 rollback complete.';
GO

SET NOEXEC OFF;
GO
