-- =====================================================================
-- 229 Driver value list -- ROLLBACK
--
-- Undoes database/229_obligation_driver_values.sql:
--   1. Restores sp_resolve_obligation_type_field_rules to the 228 body
--      (one result set: the rules only).
--   2. Drops sp_pm_infer_obligation_field_rules.
--   3. Deletes the marker rows 229 added -- the ones with
--      visible_column = '' -- leaving the rule rows 228 inferred.
--
-- THE FORM GOES BACK TO ITS OLD BEHAVIOUR, INCLUDING THE DEFECT
-- -------------------------------------------------------------
-- With no driver-value list the browser falls back to building the
-- dropdown from the rules, which is what offered EventDriven and nothing
-- else. That is the state 229 exists to fix, so roll this back only to
-- get out of a problem 229 itself caused -- not as tidying.
--
-- The rule rows are left in place. They are 228's work, still correct,
-- and re-deriving them means another pass over Control Management's
-- tables for no gain.
--
-- ASCII-only on purpose (see the forward script header).
-- Idempotent: safe to re-run.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF OBJECT_ID('grac_practice.obligation_type_field_rule','U') IS NULL
BEGIN
    PRINT 'ABORT (229 rollback): obligation_type_field_rule missing -- nothing to roll back.';
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. sp_resolve_obligation_type_field_rules -- back to the 228 body.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_resolve_obligation_type_field_rules
    @type_code NVARCHAR(60)
AS
BEGIN
    SET NOCOUNT ON;

    IF NULLIF(LTRIM(RTRIM(ISNULL(@type_code, N''))), N'') IS NULL
        THROW 52700, 'sp_resolve_obligation_type_field_rules: type_code is required.', 1;

    SELECT r.driver_column  AS DriverColumn,
           r.driver_value   AS DriverValue,
           r.visible_column AS VisibleColumn,
           r.sample_rows    AS SampleRows
    FROM   grac_practice.obligation_type_field_rule r
    WHERE  r.type_code = @type_code
    ORDER  BY r.driver_value, r.visible_column;
END
GO

PRINT '229 rollback: sp_resolve_obligation_type_field_rules restored to the 228 body.';
GO

-- =====================================================================
-- 2. Drop the inference procedure.
-- =====================================================================
IF OBJECT_ID('grac_practice.sp_pm_infer_obligation_field_rules','P') IS NOT NULL
BEGIN
    DROP PROCEDURE grac_practice.sp_pm_infer_obligation_field_rules;
    PRINT '229 rollback: sp_pm_infer_obligation_field_rules dropped.';
END
GO

-- =====================================================================
-- 3. Remove the marker rows.
-- =====================================================================
DELETE FROM grac_practice.obligation_type_field_rule
WHERE  visible_column = N'';

DECLARE @removed INT = @@ROWCOUNT;
PRINT '229 rollback: driver-value marker rows removed = ' + CAST(@removed AS NVARCHAR(20));
GO

-- =====================================================================
-- 4. Verification
-- =====================================================================
PRINT '=== 229 rollback verification ===';

DECLARE @markers INT = (SELECT COUNT(*) FROM grac_practice.obligation_type_field_rule WHERE visible_column = N'');
DECLARE @rules   INT = (SELECT COUNT(*) FROM grac_practice.obligation_type_field_rule WHERE visible_column <> N'');

SELECT 'inference procedure removed' AS Check_,
       CASE WHEN OBJECT_ID('grac_practice.sp_pm_infer_obligation_field_rules','P') IS NULL
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT 'rules procedure returns one result set',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_resolve_obligation_type_field_rules','P'))
                 LIKE '%HasRule%'
            THEN 'FAIL' ELSE 'PASS' END
UNION ALL
SELECT 'marker rows removed', CASE WHEN @markers = 0 THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT 'inferred rules retained', CAST(@rules AS NVARCHAR(20));

PRINT '';
PRINT '229 rollback complete. The trigger dropdown again offers only the';
PRINT 'values that carry a rule.';
GO

SET NOEXEC OFF;
GO
