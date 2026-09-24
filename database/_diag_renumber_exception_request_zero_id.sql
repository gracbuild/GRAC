-- =====================================================================
-- UAT REPAIR -- give the id-0 exception_request a real id (default: 1)
--               WITHOUT deleting it
--
-- WHY THE ROW CANNOT SIMPLY BE UPDATED
--   Two reasons, and both are handled below:
--
--   1. If exception_request_id is an IDENTITY, SQL Server REFUSES to
--      UPDATE it. There is no syntax for it at any privilege level.
--   2. Even where the column is not an identity, the row has children
--      (history, attachments, remediation task links) whose foreign keys
--      point at 0. Changing the parent first breaks them; changing the
--      children first points them at a row that does not exist yet.
--
--   So the only safe shape is the same in both cases:
--      insert a COPY carrying the new id  ->  repoint the children
--      ->  delete the old row  ->  reseed the identity.
--   All inside one transaction, so a failure leaves the row exactly as
--   it is now.
--
-- WHY 0 HAPPENED -- what the code says
--   Every procedure that creates an exception request omits the id
--   column and reads SCOPE_IDENTITY():
--       162 sp_exception_request_create      (Exception: <gap title>)
--       166 the v2 full-capture rewrite      (same title default)
--       258 the linked-practice rewrite      (the live one)
--       184 the SLA override path            (SLA override: <gap>)
--   NONE of them can write a 0. So the row was not produced by this
--   application's insert path as the code stands -- which points at the
--   column not being an IDENTITY on THIS database. Section 1 settles it,
--   and section 5 says what to do about it, because renumbering one row
--   does not fix a table that will do the same thing to the next one.
--
-- DRY RUN BY DEFAULT. @Apply = 0 prints the exact plan and changes
-- nothing.
--
-- ASCII-only. Re-runnable (a second run finds nothing to do).
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @Apply BIT    = 0;   -- <<< 1 to actually apply
DECLARE @OldId BIGINT = 0;   -- the broken id
DECLARE @NewId BIGINT = 1;   -- the id you want it to have

IF OBJECT_ID('grac_practice.exception_request','U') IS NULL
BEGIN
    PRINT 'exception_request does not exist here. Nothing to do.';
    RETURN;
END

-- ---------------------------------------------------------------------
PRINT '=== 1. Identity state, and whether the target id is free ======';
DECLARE @IsIdentity BIT =
    ISNULL((SELECT c.is_identity FROM sys.columns c
             WHERE c.object_id = OBJECT_ID('grac_practice.exception_request')
               AND c.name = 'exception_request_id'), 0);

SELECT @IsIdentity                                   AS IsIdentity,
       IDENT_CURRENT('grac_practice.exception_request') AS IdentityCurrent,
       CASE WHEN @IsIdentity = 1
            THEN 'identity intact -- IDENTITY_INSERT will be used for the copy'
            ELSE 'NOT an identity here -- see section 5, this WILL recur'
       END                                            AS IdentityVerdict,
       (SELECT COUNT(*) FROM grac_practice.exception_request
         WHERE exception_request_id = @OldId)          AS BadRowExists,
       (SELECT COUNT(*) FROM grac_practice.exception_request
         WHERE exception_request_id = @NewId)          AS TargetIdAlreadyTaken;

IF NOT EXISTS (SELECT 1 FROM grac_practice.exception_request
                WHERE exception_request_id = @OldId)
BEGIN
    PRINT '   No row with that id. Nothing to do.';
    RETURN;
END

IF EXISTS (SELECT 1 FROM grac_practice.exception_request
            WHERE exception_request_id = @NewId)
BEGIN
    PRINT '   *** The target id is already in use. Change @NewId at the top';
    PRINT '       to a free number and re-run. Nothing was changed.';
    RETURN;
END

-- ---------------------------------------------------------------------
PRINT '';
PRINT '=== 2. The row being renumbered ================================';
SELECT exception_request_id AS ExceptionRequestId,
       organization_id      AS OrganizationId,
       custom_gap_id        AS CustomGapId,
       request_title        AS RequestTitle,
       status_code          AS StatusCode,
       request_type_code    AS RequestTypeCode,
       requested_dt         AS RequestedOn
  FROM grac_practice.exception_request
 WHERE exception_request_id = @OldId;

PRINT '';
PRINT '=== 3. Children that will be repointed ========================';
SELECT 'exception_request_history' AS ChildTable,
       COUNT(*)                    AS Rows_
  FROM grac_practice.exception_request_history WHERE exception_request_id = @OldId
UNION ALL
SELECT 'exception_request_attachment',
       (SELECT COUNT(*) FROM grac_practice.exception_request_attachment
         WHERE exception_request_id = @OldId)
UNION ALL
SELECT 'exception_request_task',
       CASE WHEN OBJECT_ID('grac_practice.exception_request_task','U') IS NULL THEN 0
            ELSE (SELECT COUNT(*) FROM grac_practice.exception_request_task
                   WHERE exception_request_id = @OldId) END;

-- Anything ELSE that references the table. If a later migration added a
-- child this file does not know about, it shows up here and section 4
-- will refuse rather than orphan it.
PRINT '';
PRINT '--- other referencing tables (must be none, or stop) ---';
SELECT OBJECT_SCHEMA_NAME(fk.parent_object_id) + '.'
     + OBJECT_NAME(fk.parent_object_id)  AS ReferencingTable,
       c.name                            AS ViaColumn
  FROM sys.foreign_keys fk
  JOIN sys.foreign_key_columns fkc ON fkc.constraint_object_id = fk.object_id
  JOIN sys.columns c ON c.object_id = fk.parent_object_id
                    AND c.column_id = fkc.parent_column_id
 WHERE fk.referenced_object_id = OBJECT_ID('grac_practice.exception_request')
   AND OBJECT_NAME(fk.parent_object_id) NOT IN
       (N'exception_request_history', N'exception_request_attachment',
        N'exception_request_task')
 ORDER BY ReferencingTable;

-- ---------------------------------------------------------------------
PRINT '';
PRINT '=== 4. The plan ================================================';
-- The column list is built from the catalogue, NOT hand-written.
-- exception_request has gained columns across 161, 166, 184, 192, 258
-- and 260; typing the list out would be one omission away from silently
-- dropping a value during the copy.
DECLARE @cols NVARCHAR(MAX);
SELECT @cols = STRING_AGG(QUOTENAME(c.name), N', ')
                      WITHIN GROUP (ORDER BY c.column_id)
  FROM sys.columns c
 WHERE c.object_id = OBJECT_ID('grac_practice.exception_request')
   AND c.is_identity = 0
   AND c.is_computed = 0
   AND c.name <> N'exception_request_id';

DECLARE @plan NVARCHAR(MAX) =
      CASE WHEN @IsIdentity = 1
           THEN N'SET IDENTITY_INSERT grac_practice.exception_request ON;' + CHAR(13)
           ELSE N'' END
    + N'INSERT INTO grac_practice.exception_request (exception_request_id, ' + @cols + N')' + CHAR(13)
    + N'SELECT ' + CAST(@NewId AS NVARCHAR(20)) + N', ' + @cols + CHAR(13)
    + N'  FROM grac_practice.exception_request WHERE exception_request_id = '
    + CAST(@OldId AS NVARCHAR(20)) + N';' + CHAR(13)
    + CASE WHEN @IsIdentity = 1
           THEN N'SET IDENTITY_INSERT grac_practice.exception_request OFF;' + CHAR(13)
           ELSE N'' END;

PRINT '   The copy statement that will run:';
PRINT @plan;
PRINT '   then the three child UPDATEs, then DELETE the old row,';
PRINT '   then DBCC CHECKIDENT reseed (identity tables only).';

IF @Apply = 0
BEGIN
    PRINT '';
    PRINT '   @Apply = 0 -- NOTHING WAS CHANGED. Review the plan above,';
    PRINT '   then set @Apply = 1 at the top and re-run.';
    RETURN;
END

-- ---------------------------------------------------------------------
-- Refuse if an unknown child exists: repointing what we know about and
-- leaving another table pointing at a deleted row would be worse than
-- doing nothing.
IF EXISTS (SELECT 1
             FROM sys.foreign_keys fk
            WHERE fk.referenced_object_id = OBJECT_ID('grac_practice.exception_request')
              AND OBJECT_NAME(fk.parent_object_id) NOT IN
                  (N'exception_request_history', N'exception_request_attachment',
                   N'exception_request_task'))
BEGIN
    PRINT '*** ABORTED: a table this script does not handle references';
    PRINT '    exception_request (listed in section 3). Send me that list';
    PRINT '    and I will extend the script. Nothing was changed.';
    RETURN;
END

BEGIN TRY
    BEGIN TRAN;

    EXEC sp_executesql @plan;
    PRINT '   copy inserted with the new id.';

    UPDATE grac_practice.exception_request_history
       SET exception_request_id = @NewId
     WHERE exception_request_id = @OldId;
    PRINT '   history repointed.';

    UPDATE grac_practice.exception_request_attachment
       SET exception_request_id = @NewId
     WHERE exception_request_id = @OldId;
    PRINT '   attachments repointed.';

    IF OBJECT_ID('grac_practice.exception_request_task','U') IS NOT NULL
    BEGIN
        UPDATE grac_practice.exception_request_task
           SET exception_request_id = @NewId
         WHERE exception_request_id = @OldId;
        PRINT '   remediation task links repointed.';
    END

    DELETE FROM grac_practice.exception_request
     WHERE exception_request_id = @OldId;
    PRINT '   old row deleted.';

    COMMIT;

    -- Outside the transaction: DBCC is not transactional. Reseeds to the
    -- highest id present, so the next insert issues the one after it.
    IF @IsIdentity = 1
    BEGIN
        DECLARE @max BIGINT = (SELECT ISNULL(MAX(exception_request_id), 0)
                                 FROM grac_practice.exception_request);
        DECLARE @reseed NVARCHAR(300) =
            N'DBCC CHECKIDENT (''grac_practice.exception_request'', RESEED, '
            + CAST(@max AS NVARCHAR(20)) + N');';
        EXEC sp_executesql @reseed;
        PRINT '   identity reseeded above the highest id.';
    END

    PRINT '   DONE.';
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK;
    PRINT '*** ROLLED BACK -- the row is untouched. Error follows.';
    THROW;
END CATCH

-- ---------------------------------------------------------------------
PRINT '';
PRINT '=== 5. If section 1 said NOT an identity, read this ===========';
PRINT '  Renumbering this row fixes today. The NEXT auto-created';
PRINT '  exception will be broken the same way, because no creator';
PRINT '  procedure supplies the id -- they all rely on IDENTITY and read';
PRINT '  SCOPE_IDENTITY(). The column has to become an IDENTITY, which';
PRINT '  SQL Server cannot do with ALTER COLUMN: the table must be';
PRINT '  rebuilt (create alongside with IDENTITY, copy under';
PRINT '  IDENTITY_INSERT, move the child foreign keys, reseed).';
PRINT '  Tell me if that is the case and I will write it.';

SELECT exception_request_id AS ExceptionRequestId,
       request_title        AS RequestTitle,
       status_code          AS StatusCode
  FROM grac_practice.exception_request
 ORDER BY exception_request_id;
