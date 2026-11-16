-- =====================================================================
-- diagnose_change_detect_8711.sql      (read-only: every step is rolled back)
--
-- sp_repository_change_detect stops on
--   Msg 8711 "Multiple ordered aggregate functions in the same scope have
--   mutually incompatible orderings"
-- and, because it has no per-step error handling, does not say which copy
-- step raised it. This runs every step (sp_repo_change_detect_step) for
-- every subscribed organization / release ON ITS OWN, inside its own
-- transaction that is ALWAYS rolled back, and lists the ones that fail.
-- Nothing is written to organization_repository_change.
--
-- Send back the three result sets.
-- ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT OFF;   -- keep the transaction alive after a caught error

-- 1. Server version and whether the 478 classification functions are
--    inlined (an inlined ordered STRING_AGG is the known 8711 source).
SELECT N'1 server' AS [Section],
       CAST(SERVERPROPERTY('ProductVersion') AS NVARCHAR(40))      AS ProductVersion,
       CAST(SERVERPROPERTY('ProductMajorVersion') AS NVARCHAR(10)) AS MajorVersion,
       (SELECT compatibility_level FROM sys.databases WHERE name = DB_NAME()) AS CompatLevel;

SELECT N'1 functions' AS [Section], OBJECT_NAME(m.object_id) AS FunctionName,
       m.is_inlineable AS IsInlineable,
       m.inline_type   AS InlineType          -- 1 = inlining ON
FROM   sys.sql_modules m
WHERE  m.object_id IN (OBJECT_ID('grac_practice.fn_repo_statement_classification_ids'),
                       OBJECT_ID('grac_practice.fn_repo_statement_classification_names'));
GO

-- 2. Every step, every organization / release, one at a time.
DECLARE @result TABLE(
    organization_id BIGINT, release_id BIGINT, copy_code NVARCHAR(40),
    error_number INT, error_message NVARCHAR(4000));

DECLARE @org BIGINT, @rid BIGINT, @code NVARCHAR(40), @n INT,
        @run UNIQUEIDENTIFIER = NEWID();

DECLARE work_cur CURSOR LOCAL FAST_FORWARD FOR
    -- Added / Changed: per subscribed release
    SELECT DISTINCT s.organization_id, s.release_id, c.copy_code
    FROM   grac_practice.repository_subscription s
    JOIN   grac_new.release r ON r.release_id = s.release_id
    CROSS JOIN grac_practice.repository_copy_config c
    WHERE  s.status = 'Active'
      AND  ISNULL(s.subscription_status, 'Active') = 'Active'
      AND  c.status = N'Active'
    UNION
    -- Retired: once per organization (release NULL)
    SELECT DISTINCT s.organization_id, NULL, c.copy_code
    FROM   grac_practice.repository_subscription s
    CROSS JOIN grac_practice.repository_copy_config c
    WHERE  s.status = 'Active'
      AND  ISNULL(s.subscription_status, 'Active') = 'Active'
      AND  c.status = N'Active';

OPEN work_cur;
FETCH NEXT FROM work_cur INTO @org, @rid, @code;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRANSACTION;
    BEGIN TRY
        EXEC grac_practice.sp_repo_change_detect_step
             @copy_code = @code, @organization_id = @org, @release_id = @rid,
             @run_id = @run, @actor = N'diagnose-8711', @raised = @n OUTPUT;
        INSERT @result VALUES (@org, @rid, @code, NULL, NULL);
    END TRY
    BEGIN CATCH
        INSERT @result VALUES (@org, @rid, @code, ERROR_NUMBER(), ERROR_MESSAGE());
    END CATCH;
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;   -- never keep what the step wrote
    FETCH NEXT FROM work_cur INTO @org, @rid, @code;
END
CLOSE work_cur;
DEALLOCATE work_cur;

-- Which steps fail (the answer)
SELECT N'2 failing steps' AS [Section], copy_code AS CopyCode,
       CASE WHEN release_id IS NULL THEN N'Retired pass' ELSE N'Added/Changed pass' END AS Pass,
       COUNT(*) AS Failures, MIN(error_number) AS ErrorNumber, MIN(error_message) AS ErrorMessage
FROM   @result
WHERE  error_number IS NOT NULL
GROUP BY copy_code, CASE WHEN release_id IS NULL THEN N'Retired pass' ELSE N'Added/Changed pass' END
ORDER BY copy_code;

-- Which steps pass
SELECT N'3 passing steps' AS [Section], copy_code AS CopyCode, COUNT(*) AS Runs
FROM   @result
WHERE  error_number IS NULL
GROUP BY copy_code
ORDER BY copy_code;
GO
