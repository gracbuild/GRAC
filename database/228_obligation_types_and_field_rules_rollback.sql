-- =====================================================================
-- 228 Obligation taxonomy and field rules -- ROLLBACK
--
-- Undoes database/228_obligation_types_and_field_rules.sql:
--   1. Restores sp_resolve_obligation_type_fields to the 227 body, with
--      Evidence and Retention back in the type map.
--   2. Drops sp_resolve_obligation_type_field_rules and the
--      obligation_type_field_rule table.
--   3. Leaves vw_pm_obligation_typed_detail ALONE. See below.
--
-- THE VIEW IS NOT PUT BACK
-- ------------------------
-- 228 rebuilt it from whichever GRAC_New detail tables exist. Restoring
-- the 225 body would hard-code the six table names again -- and if
-- Control Management has since dropped one, the view compiles at deploy
-- and then fails the next time somebody opens Operationalize, with
-- "Invalid object name". That is a worse state than the one being
-- rolled back to.
--
-- The 228 view is a superset in behaviour: with every table present it
-- produces exactly what 225 produced. There is nothing to gain by
-- reverting it and a live outage to lose.
--
-- If it genuinely has to go back, re-run 225 explicitly and satisfy
-- yourself first that all six tables are there:
--
--     SELECT name FROM sys.tables
--     WHERE  schema_id = SCHEMA_ID('GRAC_New')
--       AND  name IN ('obligation_state_rule','obligation_execution_spec',
--                     'obligation_assurance_spec','obligation_event_response',
--                     'obligation_constraint_rule','obligation_retention_spec');
--
-- THE BROWSER NEEDS NO ROLLBACK
-- -----------------------------
-- With the rules procedure gone the form's fetch returns non-OK, the
-- rule map stays empty, and every field shows -- which is the documented
-- fallback, not a failure.
--
-- ASCII-only on purpose (see the forward script header).
-- Idempotent: safe to re-run.
-- =====================================================================
SET NOCOUNT ON;
SET NOEXEC OFF;
GO

IF SCHEMA_ID('grac_practice') IS NULL OR SCHEMA_ID('GRAC_New') IS NULL
BEGIN
    PRINT 'ABORT (228 rollback): schema grac_practice or GRAC_New missing.';
    SET NOEXEC ON;
END
GO

-- =====================================================================
-- 1. sp_resolve_obligation_type_fields -- back to the 227 body.
-- =====================================================================
CREATE OR ALTER PROCEDURE grac_practice.sp_resolve_obligation_type_fields
    @type_code NVARCHAR(60)
AS
BEGIN
    SET NOCOUNT ON;

    IF NULLIF(LTRIM(RTRIM(ISNULL(@type_code, N''))), N'') IS NULL
        THROW 52690, 'sp_resolve_obligation_type_fields: type_code is required.', 1;

    DECLARE @norm NVARCHAR(60) =
        LOWER(REPLACE(REPLACE(REPLACE(LTRIM(RTRIM(@type_code)), N'_', N''), N'-', N''), N' ', N''));

    DECLARE @table SYSNAME = (
        SELECT TOP 1 t.table_name
        FROM (VALUES
            (N'state',         N'obligation_state_rule'),
            (N'staterule',     N'obligation_state_rule'),
            (N'execution',     N'obligation_execution_spec'),
            (N'executionspec', N'obligation_execution_spec'),
            (N'assurance',     N'obligation_assurance_spec'),
            (N'assurancespec', N'obligation_assurance_spec'),
            (N'eventresponse', N'obligation_event_response'),
            (N'event',         N'obligation_event_response'),
            (N'constraint',    N'obligation_constraint_rule'),
            (N'constraintrule',N'obligation_constraint_rule'),
            (N'retention',     N'obligation_retention_spec'),
            (N'retentionspec', N'obligation_retention_spec'),
            (N'evidence',      N'requirement_obligation_evidence')
        ) AS t(code, table_name)
        WHERE t.code = @norm);

    IF @table IS NULL
    BEGIN
        -- Not an error: a type with no detail table simply has no rule
        -- fields, and the form should show none rather than refuse.
        --
        -- The empty set still has to have the SAME SHAPE as the populated
        -- one -- INSERT ... EXEC matches by position and fails on a
        -- column-count mismatch, and the verification block below does
        -- exactly that.
        SELECT CAST(NULL AS SYSNAME)  AS TableName,
               CAST(NULL AS SYSNAME)  AS ColumnName,
               CAST(NULL AS SYSNAME)  AS DataType,
               CAST(NULL AS INT)      AS MaxLength,
               CAST(NULL AS BIT)      AS IsNullable,
               CAST(NULL AS INT)      AS Ordinal,
               CAST(NULL AS BIT)      AS IsReference
        WHERE  1 = 0;
        RETURN;
    END

    -- Housekeeping columns are the ones the form must never offer: the
    -- surrogate key, the owning id, the row's own status and audit
    -- stamps. Everything else is a field Control Management captures.
    SELECT @table                       AS TableName,
           c.name                       AS ColumnName,
           ty.name                      AS DataType,
           c.max_length                 AS MaxLength,
           c.is_nullable                AS IsNullable,
           c.column_id                  AS Ordinal,
           CAST(CASE WHEN c.name LIKE '%[_]id' THEN 1 ELSE 0 END AS BIT) AS IsReference
    FROM   sys.columns c
    JOIN   sys.tables  t  ON t.object_id = c.object_id
    JOIN   sys.schemas s  ON s.schema_id = t.schema_id
    JOIN   sys.types   ty ON ty.user_type_id = c.user_type_id
    WHERE  s.name = 'GRAC_New'
      AND  t.name = @table
      AND  c.is_computed = 0
      AND  c.name NOT IN ('obligation_id', 'status', 'record_status_id',
                          'entered_by', 'entered_dt', 'updated_by', 'updated_dt',
                          'display_order', 'is_active')
      AND  c.name <> (SELECT TOP 1 c2.name FROM sys.columns c2
                       WHERE c2.object_id = t.object_id AND c2.is_identity = 1)
    ORDER  BY c.column_id;
END
GO

PRINT '228 rollback: sp_resolve_obligation_type_fields restored to the 227 body.';
GO

-- =====================================================================
-- 2. Drop what 228 added.
-- =====================================================================
IF OBJECT_ID('grac_practice.sp_resolve_obligation_type_field_rules','P') IS NOT NULL
BEGIN
    DROP PROCEDURE grac_practice.sp_resolve_obligation_type_field_rules;
    PRINT '228 rollback: sp_resolve_obligation_type_field_rules dropped.';
END
GO

IF OBJECT_ID('grac_practice.obligation_type_field_rule','U') IS NOT NULL
BEGIN
    -- Nothing but 228 writes this table, and its whole content is
    -- re-derivable by re-running 228, so dropping it loses nothing.
    DROP TABLE grac_practice.obligation_type_field_rule;
    PRINT '228 rollback: obligation_type_field_rule dropped.';
END
GO

-- =====================================================================
-- 3. Verification
-- =====================================================================
PRINT '=== 228 rollback verification ===';

SELECT 'Evidence and Retention offered again' AS Check_,
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_resolve_obligation_type_fields','P'))
                 LIKE '%requirement_obligation_evidence%'
            THEN 'PASS' ELSE 'FAIL' END AS Result
UNION ALL
SELECT 'rule objects removed',
       CASE WHEN OBJECT_ID('grac_practice.sp_resolve_obligation_type_field_rules','P') IS NULL
             AND OBJECT_ID('grac_practice.obligation_type_field_rule','U') IS NULL
            THEN 'PASS' ELSE 'FAIL' END
UNION ALL
SELECT 'view left as 228 built it (deliberate)',
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.vw_pm_obligation_typed_detail','V'))
                 LIKE '%migration 228%'
            THEN 'YES -- see the header' ELSE 'no' END;

PRINT '';
PRINT '228 rollback complete. The add form shows every rule field again.';
GO

SET NOEXEC OFF;
GO
