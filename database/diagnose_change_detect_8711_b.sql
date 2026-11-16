-- =====================================================================
-- diagnose_change_detect_8711_b.sql   (read-only; writes nothing)
--
-- 514 did not clear Msg 8711 on the Statement copy step.  This shows the
-- objects the Statement step reads AS THEY ARE ON THIS DATABASE, then runs
-- each piece of the step on its own so the one that raises 8711 is named.
-- Send back every result set (the definitions can be long -- copy the
-- whole cell).
-- ASCII-only.
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT OFF;

-- 1. Is 514 in place?
SELECT N'1 514 applied' AS [Section],
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('grac_practice.sp_repo_change_detect_step')) LIKE '%INTO #src%'
            THEN N'yes' ELSE N'NO' END AS Result;

-- 2. The live definitions the Statement step depends on.
SELECT N'2 definition' AS [Section], v.name AS ObjectName,
       OBJECT_DEFINITION(OBJECT_ID(v.name)) AS Definition
FROM (VALUES (N'grac_practice.vw_repo_src_framework_statement'),
             (N'grac_practice.fn_repo_statement_classification_ids'),
             (N'grac_practice.fn_repo_statement_classification_names')) v(name);

SELECT N'2 copy config' AS [Section], c.copy_code, c.source_view, c.target_table,
       c.key_column, c.scope_sql, c.label_sql
FROM   grac_practice.repository_copy_config c
WHERE  c.copy_code = N'Statement';

-- Computed columns / triggers on the two tables involved.
SELECT N'2 computed columns' AS [Section], OBJECT_SCHEMA_NAME(cc.object_id) + N'.' + OBJECT_NAME(cc.object_id) AS TableName,
       cc.name AS ColumnName, cc.definition AS Definition
FROM   sys.computed_columns cc
WHERE  cc.object_id IN (OBJECT_ID('grac_new.framework_statement'),
                        OBJECT_ID('grac_practice.organization_framework_statements'));
SELECT N'2 triggers' AS [Section], OBJECT_NAME(t.parent_id) AS TableName, t.name AS TriggerName
FROM   sys.triggers t
WHERE  t.parent_id IN (OBJECT_ID('grac_practice.organization_repository_change'),
                       OBJECT_ID('grac_practice.organization_framework_statements'));
GO

-- 3. Each piece of the Statement step, on its own.
DECLARE @org BIGINT, @rid BIGINT;
SELECT TOP (1) @org = s.organization_id, @rid = s.release_id
FROM   grac_practice.repository_subscription s
WHERE  s.status = 'Active' AND ISNULL(s.subscription_status, 'Active') = 'Active'
ORDER BY s.organization_id, s.release_id;

DECLARE @r TABLE(step NVARCHAR(60), result NVARCHAR(10), error NVARCHAR(4000));
DECLARE @sql NVARCHAR(MAX);
DECLARE @p NVARCHAR(200) = N'@organization_id BIGINT, @release_id BIGINT';

-- a. read the whole view
BEGIN TRY
    EXEC sp_executesql N'DECLARE @c INT; SELECT @c = COUNT(*) FROM grac_practice.vw_repo_src_framework_statement;';
    INSERT @r VALUES (N'a count view', N'ok', NULL);
END TRY BEGIN CATCH INSERT @r VALUES (N'a count view', N'FAIL', CONCAT(ERROR_NUMBER(), N': ', ERROR_MESSAGE())); END CATCH;

-- b. read every column of the view
BEGIN TRY
    EXEC sp_executesql N'SELECT v.* INTO #b FROM grac_practice.vw_repo_src_framework_statement v;';
    INSERT @r VALUES (N'b select * into (all rows)', N'ok', NULL);
END TRY BEGIN CATCH INSERT @r VALUES (N'b select * into (all rows)', N'FAIL', CONCAT(ERROR_NUMBER(), N': ', ERROR_MESSAGE())); END CATCH;

-- c. the 514 copy, scoped to one release
BEGIN TRY
    EXEC sp_executesql N'SELECT src.* INTO #c FROM grac_practice.vw_repo_src_framework_statement src
                         WHERE src.release_id = @release_id AND src.status = N''Active'';', @p,
         @organization_id = @org, @release_id = @rid;
    INSERT @r VALUES (N'c select * into (one release)', N'ok', NULL);
END TRY BEGIN CATCH INSERT @r VALUES (N'c select * into (one release)', N'FAIL', CONCAT(ERROR_NUMBER(), N': ', ERROR_MESSAGE())); END CATCH;

-- d. FOR JSON snapshot over the copied rows
BEGIN TRY
    EXEC sp_executesql N'SELECT src.* INTO #d FROM grac_practice.vw_repo_src_framework_statement src
                         WHERE src.release_id = @release_id AND src.status = N''Active'';
                         DECLARE @j NVARCHAR(MAX);
                         SELECT TOP (5) @j = (SELECT s2.* FROM #d s2 WHERE s2.framework_statement_id = src.framework_statement_id
                                              FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)
                         FROM #d src;', @p,
         @organization_id = @org, @release_id = @rid;
    INSERT @r VALUES (N'd json over #copy', N'ok', NULL);
END TRY BEGIN CATCH INSERT @r VALUES (N'd json over #copy', N'FAIL', CONCAT(ERROR_NUMBER(), N': ', ERROR_MESSAGE())); END CATCH;

-- e. the copy table snapshot (old_snapshot_json)
BEGIN TRY
    EXEC sp_executesql N'DECLARE @j NVARCHAR(MAX);
                         SELECT TOP (5) @j = (SELECT t2.* FROM grac_practice.organization_framework_statements t2
                                              WHERE t2.org_statement_id = t.org_statement_id
                                              FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)
                         FROM grac_practice.organization_framework_statements t
                         WHERE t.organization_id = @organization_id;', @p,
         @organization_id = @org, @release_id = @rid;
    INSERT @r VALUES (N'e json over copy table', N'ok', NULL);
END TRY BEGIN CATCH INSERT @r VALUES (N'e json over copy table', N'FAIL', CONCAT(ERROR_NUMBER(), N': ', ERROR_MESSAGE())); END CATCH;

-- f. the label
BEGIN TRY
    SET @sql = N'DECLARE @l NVARCHAR(500); SELECT TOP (5) @l = LEFT('
             + REPLACE((SELECT label_sql FROM grac_practice.repository_copy_config WHERE copy_code = N'Statement'), N'{a}', N'src')
             + N', 500) FROM grac_practice.vw_repo_src_framework_statement src;';
    EXEC sp_executesql @sql;
    INSERT @r VALUES (N'f label', N'ok', NULL);
END TRY BEGIN CATCH INSERT @r VALUES (N'f label', N'FAIL', CONCAT(ERROR_NUMBER(), N': ', ERROR_MESSAGE())); END CATCH;

-- g. the whole step, rolled back
BEGIN TRANSACTION;
BEGIN TRY
    DECLARE @n INT, @run UNIQUEIDENTIFIER = NEWID();
    EXEC grac_practice.sp_repo_change_detect_step
         @copy_code = N'Statement', @organization_id = @org, @release_id = @rid,
         @run_id = @run, @actor = N'diagnose-8711-b', @raised = @n OUTPUT;
    INSERT @r VALUES (N'g whole Statement step', N'ok', NULL);
END TRY BEGIN CATCH INSERT @r VALUES (N'g whole Statement step', N'FAIL', CONCAT(ERROR_NUMBER(), N': ', ERROR_MESSAGE(), N' (line ', ERROR_LINE(), N', proc ', ISNULL(ERROR_PROCEDURE(), N'-'), N')')); END CATCH;
IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;

SELECT N'3 pieces' AS [Section], @org AS OrganizationId, @rid AS ReleaseId, step AS Piece, result AS Result, error AS Error
FROM   @r;
GO
