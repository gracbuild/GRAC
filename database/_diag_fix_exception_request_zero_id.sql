-- =====================================================================
-- UAT REPAIR -- exception_request row with exception_request_id = 0
--
-- WHAT WE KNOW ALREADY
--   _diag_uat_exception_analysis_prereqs.sql reported every procedure
--   present, 257 applied, 258/259/260 applied -- and one row:
--
--       ExceptionRequestId = 0
--       StatusCode         = Pending
--       RequestTitle       = Exception: Govern threat intelligence-Network
--
--   That id is why Analysis fails. exception-centre.js writes
--   data-exc-menu from it, the menu builds "?exceptionId=0", and
--   exception-analysis.js requires a value GREATER THAN ZERO -- so it
--   reports "No exception request was specified". The page is right; the
--   row is wrong.
--
-- WHY THE ROW IS IMPOSSIBLE
--   161 declares the column:
--       exception_request_id BIGINT IDENTITY(1,1) NOT NULL PRIMARY KEY
--   An IDENTITY(1,1) never issues 0. So this row did NOT come from a
--   normal insert. Section 1 establishes which of the two explanations
--   applies, because THE FIX IS DIFFERENT FOR EACH:
--
--     A. The column IS an IDENTITY -> somebody inserted with
--        SET IDENTITY_INSERT ON and an explicit 0 (a data load, a
--        migrated row, a hand-written seed).
--     B. The column is NOT an IDENTITY on this database -> the table was
--        not created by 161 here (a restore from an older schema, or a
--        hand-built table). Then EVERY new request is at risk, not just
--        this one, and the table itself needs correcting.
--
-- DEFAULT BEHAVIOUR: REPORT ONLY. Nothing is modified unless you set
-- @Apply = 1 in section 3, and even then only the delete runs -- there
-- is no automatic identity surgery in this file.
--
-- ASCII-only. Re-runnable.
-- =====================================================================
SET NOCOUNT ON;

IF OBJECT_ID('grac_practice.exception_request','U') IS NULL
BEGIN
    PRINT 'exception_request does not exist on this database. Run 161 first.';
    RETURN;
END

PRINT '=== 1. Is the primary key an IDENTITY here? ====================';
SELECT c.name                            AS ColumnName,
       t.name                            AS DataType,
       c.is_identity                     AS IsIdentity,
       IDENT_SEED('grac_practice.exception_request')      AS IdentitySeed,
       IDENT_INCR('grac_practice.exception_request')      AS IdentityIncrement,
       IDENT_CURRENT('grac_practice.exception_request')   AS IdentityCurrent,
       CASE WHEN c.is_identity = 1
            THEN 'CASE A -- identity is intact; the 0 row was force-inserted'
            ELSE 'CASE B -- NOT an identity on this database; the table needs correcting'
       END                               AS Verdict
  FROM sys.columns c
  JOIN sys.types   t ON t.user_type_id = c.user_type_id
 WHERE c.object_id = OBJECT_ID('grac_practice.exception_request')
   AND c.name = 'exception_request_id';

PRINT '';
PRINT '=== 2. The bad rows, and everything that references them =======';
SELECT COUNT(*)                                  AS RowsWithIdZeroOrLess
  FROM grac_practice.exception_request
 WHERE exception_request_id <= 0;

SELECT exception_request_id  AS ExceptionRequestId,
       organization_id       AS OrganizationId,
       custom_gap_id         AS CustomGapId,
       request_title         AS RequestTitle,
       status_code           AS StatusCode,
       requested_dt          AS RequestedOn
  FROM grac_practice.exception_request
 WHERE exception_request_id <= 0;

-- FKs discovered, not assumed: this reports every table that points at
-- exception_request, so nothing is missed if a later migration added
-- another child.
PRINT '';
PRINT '--- children of the bad row(s), per referencing table ---';
DECLARE @sql NVARCHAR(MAX) = N'';

SELECT @sql = @sql + N'
SELECT ' + QUOTENAME(OBJECT_SCHEMA_NAME(fk.parent_object_id) + N'.'
                   + OBJECT_NAME(fk.parent_object_id), '''') + N' AS ChildTable,
       ' + QUOTENAME(c.name, '''') + N' AS ViaColumn,
       COUNT(*) AS RowsPointingAtBadIds
  FROM ' + QUOTENAME(OBJECT_SCHEMA_NAME(fk.parent_object_id)) + N'.'
         + QUOTENAME(OBJECT_NAME(fk.parent_object_id)) + N'
 WHERE ' + QUOTENAME(c.name) + N' <= 0
UNION ALL'
  FROM sys.foreign_keys fk
  JOIN sys.foreign_key_columns fkc
    ON fkc.constraint_object_id = fk.object_id
  JOIN sys.columns c
    ON c.object_id = fk.parent_object_id
   AND c.column_id = fkc.parent_column_id
 WHERE fk.referenced_object_id = OBJECT_ID('grac_practice.exception_request');

IF @sql = N''
    PRINT '   (nothing references exception_request)';
ELSE
BEGIN
    -- Trim the trailing UNION ALL and close the statement.
    SET @sql = LEFT(@sql, LEN(@sql) - LEN(N'UNION ALL')) + N';';
    EXEC sp_executesql @sql;
END

PRINT '';
PRINT '=== 3. Repair ==================================================';
-- ---------------------------------------------------------------------
-- THE RECOMMENDED FIX IS NOT IN THIS FILE, and that is deliberate.
--
-- This is one Pending request on UAT with no decision recorded against
-- it. The cleanest repair is to DELETE it and raise it again from its
-- Gap through the UI -- the insert then goes through
-- sp_exception_request_create, IDENTITY issues a proper id, and the row
-- is correct by construction rather than by surgery.
--
-- Renumbering it in place is NOT possible: an IDENTITY column cannot be
-- UPDATEd. The alternative would be insert-a-copy / re-point-children /
-- delete-the-original, which is three chances to get a foreign key
-- wrong for a row that carries no decision worth preserving.
--
-- So: set @Apply = 1 to delete the bad row(s) and their children, then
-- re-raise the exception from Gap Centre.
--
-- IF SECTION 1 SAID CASE B, DO NOT STOP HERE. Deleting the row fixes
-- today's symptom and the next request will be broken the same way.
-- The column has to become an IDENTITY, which means rebuilding the
-- table (SQL Server cannot ALTER a column into an identity):
--   1. script exception_request out with its constraints and indexes,
--   2. create it with exception_request_id BIGINT IDENTITY(1,1),
--   3. SET IDENTITY_INSERT ON, copy the good rows, IDENTITY_INSERT OFF,
--   4. re-create the child foreign keys,
--   5. DBCC CHECKIDENT to reseed above the highest copied id.
-- Do that in a maintenance window, with a backup, against UAT first.
-- Tell me if section 1 says CASE B and I will write that script.
-- ---------------------------------------------------------------------
DECLARE @Apply BIT = 0;   -- <<< set to 1 to actually delete

IF @Apply = 0
BEGIN
    PRINT '   @Apply = 0 -- nothing was changed.';
    PRINT '   Read sections 1 and 2, then set @Apply = 1 to delete the';
    PRINT '   bad row(s) and re-raise the exception from Gap Centre.';
END
ELSE
BEGIN
    IF NOT EXISTS (SELECT 1 FROM grac_practice.exception_request
                    WHERE exception_request_id <= 0)
        PRINT '   Nothing to delete -- no row has an id of 0 or less.';
    ELSE
    BEGIN
        BEGIN TRY
            BEGIN TRAN;

            -- Children first, in FK order. Named explicitly rather than
            -- discovered, because a DELETE is not something to drive
            -- from dynamic SQL built out of catalogue views.
            IF OBJECT_ID('grac_practice.exception_request_task','U') IS NOT NULL
            BEGIN
                DELETE FROM grac_practice.exception_request_task
                 WHERE exception_request_id <= 0;
                PRINT '   exception_request_task rows deleted.';
            END

            IF OBJECT_ID('grac_practice.exception_request_attachment','U') IS NOT NULL
            BEGIN
                DELETE FROM grac_practice.exception_request_attachment
                 WHERE exception_request_id <= 0;
                PRINT '   exception_request_attachment rows deleted.';
            END

            IF OBJECT_ID('grac_practice.exception_request_history','U') IS NOT NULL
            BEGIN
                DELETE FROM grac_practice.exception_request_history
                 WHERE exception_request_id <= 0;
                PRINT '   exception_request_history rows deleted.';
            END

            DELETE FROM grac_practice.exception_request
             WHERE exception_request_id <= 0;
            PRINT '   exception_request row(s) deleted.';

            COMMIT;
            PRINT '   Done. Re-raise the exception from Gap Centre.';
        END TRY
        BEGIN CATCH
            IF @@TRANCOUNT > 0 ROLLBACK;
            PRINT '   ROLLED BACK. Most likely another table still points at';
            PRINT '   the bad id -- check section 2s child list and tell me';
            PRINT '   which table it named.';
            THROW;
        END CATCH
    END
END

PRINT '';
PRINT '=== 4. Confirm ================================================';
SELECT COUNT(*) AS RowsStillWithIdZeroOrLess
  FROM grac_practice.exception_request
 WHERE exception_request_id <= 0;
